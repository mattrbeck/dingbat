// A stateful appDataFolder for the sync race tests: several devices (loadApp
// instances) can share one, requests can be held mid-flight so a test can act
// inside an await, and every request is logged with the token it carried.
//
// Unlike the per-file fakes in sync.test.mjs it keeps a *list* of files, not
// a map, because Drive does: two devices can each create a file called
// "library", and a listing can come back in pages.

import { jsonRes, bytesRes, u8 } from "./helpers.mjs";

export const FILES = "https://www.googleapis.com/drive/v3/files";
export const UPLOAD = "https://www.googleapis.com/upload/drive/v3/files";

// `clock` stamps modifiedTime/createdTime (ms); `pageSize` caps a listing
// page below what the app asks for, to exercise nextPageToken.
export const makeDrive = ({ seed = {}, clock, pageSize = Infinity } = {}) => {
  const files = [];
  let idc = 0;
  let tick = Date.parse("2026-01-01T00:00:00Z");
  const now = () => (clock ? clock() : (tick += 1000));
  const iso = (ms) => new Date(ms).toISOString();
  const add = (name, bytes) => {
    const t = now();
    const f = { id: "f" + idc++, name, bytes, modifiedTime: iso(t), createdTime: iso(t) };
    files.push(f);
    return f;
  };
  for (const [n, b] of Object.entries(seed)) {
    add(n, typeof b === "string" || !(b instanceof Uint8Array)
      ? new TextEncoder().encode(typeof b === "string" ? b : JSON.stringify(b)) : b);
  }
  const byId = (id) => files.find((f) => f.id === id);
  // Drive merges appProperties key by key on an update; null removes a key.
  const setProps = (f, props) => {
    const next = { ...(f.appProperties || {}) };
    for (const [k, v] of Object.entries(props)) {
      if (v == null) delete next[k];
      else next[k] = String(v);
    }
    f.appProperties = Object.keys(next).length ? next : undefined;
  };
  const log = [];
  const holds = [];

  // Pause the next request `pred` accepts until `release()`; `reached`
  // resolves once it is waiting.
  const hold = (pred) => {
    let release, reached;
    const h = {
      pred,
      gate: new Promise((r) => { release = r; }),
      reached: new Promise((r) => { reached = r; }),
    };
    h.release = () => release();
    h._reached = () => reached();
    holds.push(h);
    return h;
  };

  const fetch = async (url, opts = {}) => {
    url = String(url);
    const method = opts.method || "GET";
    const auth = opts.headers?.Authorization || null;
    const entry = { method, url, auth };
    log.push(entry);
    const h = holds.find((x) => x.pred(entry));
    if (h) {
      holds.splice(holds.indexOf(h), 1);
      h._reached();
      await h.gate;
    }
    if (url.startsWith("https://oauth2.googleapis.com/")) return jsonRes({});
    if (url.startsWith(FILES + "?spaces=appDataFolder")) {
      const q = new URL(url).searchParams;
      const size = Math.min(Number(q.get("pageSize")) || 100, pageSize);
      const start = Number(q.get("pageToken") || 0);
      // Drive returns appProperties only to a listing that asks for them.
      const props = (q.get("fields") || "").includes("appProperties");
      const page = files.slice(start, start + size).map((f) => ({
        id: f.id, name: f.name, size: String(f.bytes.length),
        modifiedTime: f.modifiedTime, createdTime: f.createdTime,
        ...(props && f.appProperties ? { appProperties: { ...f.appProperties } } : {}),
      }));
      const more = start + size < files.length;
      return jsonRes(more ? { files: page, nextPageToken: String(start + size) }
                          : { files: page });
    }
    const dm = url.match(/\/drive\/v3\/files\/([^/?]+)\?alt=media/);
    if (dm && method === "GET") {
      const f = byId(dm[1]);
      return f ? bytesRes(f.bytes) : jsonRes({}, 404);
    }
    const meta = url.match(/\/drive\/v3\/files\/([^/?]+)\?fields=/);
    if (meta && method === "PATCH") {
      const f = byId(meta[1]);
      if (!f) return jsonRes({}, 404);
      const body = JSON.parse(opts.body);
      if (body.name) f.name = body.name;
      if (body.appProperties) setProps(f, body.appProperties);
      f.modifiedTime = iso(now());
      entry.name = f.name;
      return jsonRes({ id: f.id, name: f.name, modifiedTime: f.modifiedTime });
    }
    const del = url.match(/\/drive\/v3\/files\/([^/?]+)$/);
    if (del && method === "DELETE") {
      const i = files.findIndex((f) => f.id === del[1]);
      if (i < 0) return jsonRes({}, 404);
      entry.name = files[i].name;
      files.splice(i, 1);
      return jsonRes({}, 204);
    }
    const multipart = async () => {
      const text = await opts.body.text();
      const meta = JSON.parse(text.match(/\r\n\r\n(\{.*?\})\r\n--/s)[1]);
      const mark = "application/octet-stream\r\n\r\n";
      const payload = text.slice(text.indexOf(mark) + mark.length, text.lastIndexOf("\r\n--"));
      return { meta, bytes: new TextEncoder().encode(payload) };
    };
    if (url.startsWith(UPLOAD + "?uploadType=multipart") && method === "POST") {
      const { meta, bytes } = await multipart();
      const f = add(meta.name, bytes);
      if (meta.appProperties) setProps(f, meta.appProperties);
      entry.name = meta.name;
      return jsonRes({ id: f.id, modifiedTime: f.modifiedTime });
    }
    if (url === FILES && method === "POST") {           // driveCreateEmpty
      const meta = JSON.parse(opts.body);
      const f = add(meta.name, u8());
      if (meta.appProperties) setProps(f, meta.appProperties);
      entry.name = f.name;
      return jsonRes({ id: f.id });
    }
    // Content and metadata in one update (files.update, uploadType=multipart).
    const mpatch = url.match(/\/upload\/drive\/v3\/files\/([^/?]+)\?uploadType=multipart/);
    if (mpatch && method === "PATCH") {
      const f = byId(mpatch[1]);
      if (!f) return jsonRes({}, 404);
      const { meta, bytes } = await multipart();
      f.bytes = bytes;
      if (meta.name) f.name = meta.name;
      if (meta.appProperties) setProps(f, meta.appProperties);
      f.modifiedTime = iso(now());
      entry.name = f.name;
      return jsonRes({ id: f.id, modifiedTime: f.modifiedTime });
    }
    const media = url.match(/\/upload\/drive\/v3\/files\/([^/?]+)\?uploadType=media/);
    if (media && method === "PATCH") {
      const f = byId(media[1]);
      if (!f) return jsonRes({}, 404);
      f.bytes = new Uint8Array(await opts.body.arrayBuffer());
      f.modifiedTime = iso(now());
      entry.name = f.name;
      return jsonRes({ id: f.id, modifiedTime: f.modifiedTime });
    }
    throw new Error("unexpected " + method + " " + url);
  };

  const named = (name) => files.filter((f) => f.name === name);
  const text = (f) => new TextDecoder().decode(f.bytes);
  return {
    files, log, hold, fetch, add,
    // Plant a second file under an existing name, as a racing device would.
    addDuplicate: (name, obj) => add(name, new TextEncoder().encode(JSON.stringify(obj))),
    get: (name) => named(name)[0] || null,
    named,
    names: () => files.map((f) => f.name).filter((n) => n !== "library").sort(),
    lib: () => {
      const libs = named("library");
      if (libs.length !== 1) throw new Error(libs.length + " library files on Drive");
      return JSON.parse(text(libs[0]));
    },
    writes: () => log.filter((e) => e.method !== "GET"),
  };
};

// One shared wall clock for every device in a test (and the Drive fake), so
// timestamps order the way the story says they do.
export const makeClock = (start = Date.parse("2026-03-01T00:00:00Z")) => {
  let t = start;
  const clock = () => (t += 1000);
  clock.peek = () => t;
  return clock;
};
export const useClock = (app, clock) => { app.context.__clock = clock; app.runIn("Date.now = () => __clock()"); };

// Wait (bounded) until `cond()` holds, letting the app's promise chains run.
export const until = async (cond, what = "condition") => {
  for (let i = 0; i < 200; i++) {
    if (cond()) return;
    await new Promise((r) => setTimeout(r, 0));
  }
  throw new Error("timed out waiting for " + what);
};
