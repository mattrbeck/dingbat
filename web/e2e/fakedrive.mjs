// One Google Drive appDataFolder shared by every browser context ("device")
// in a test, answering the Drive v3 calls web/index.js makes, plus
// tokeninfo and an empty Google sign-in script. Requests are routed here by
// Playwright (context.route), so nothing leaves the machine. Unlike the
// node:vm fake in web/tests/drivefake.mjs this one carries real binary
// bodies: a session is a save state and a JPEG.

export const makeDrive = () => {
  const files = [];
  const log = [];
  let idc = 0;
  // Drive's clock: every write is a second after the last, so modifiedTime
  // orders writes the way they happened.
  let clock = Date.parse("2026-09-30T10:00:00Z");
  const stamp = () => new Date((clock += 1000)).toISOString();
  const meta = (f) => ({
    id: f.id, name: f.name, size: String(f.bytes.length),
    modifiedTime: f.modifiedTime, createdTime: f.createdTime,
    ...(f.appProperties ? { appProperties: f.appProperties } : {}),
  });
  // Drive merges appProperties key by key on an update; null removes a key.
  const setProps = (f, props) => {
    const next = { ...(f.appProperties || {}) };
    for (const [k, v] of Object.entries(props || {})) {
      if (v == null) delete next[k]; else next[k] = String(v);
    }
    f.appProperties = Object.keys(next).length ? next : undefined;
  };
  // multipart/related: the JSON metadata part, then the bytes.
  const multipart = (contentType, body) => {
    const boundary = /boundary=([^;]+)/.exec(contentType)[1];
    const parts = body.toString("latin1").split("--" + boundary).slice(1, -1).map((p) => {
      let content = p.slice(p.indexOf("\r\n\r\n") + 4);
      if (content.endsWith("\r\n")) content = content.slice(0, -2);
      return Buffer.from(content, "latin1");
    });
    return { meta: JSON.parse(parts[0].toString("utf8")), bytes: parts[1] };
  };

  const handle = async (route, who) => {
    const req = route.request();
    const url = new URL(req.url());
    const method = req.method();
    const json = (o, status = 200) => route.fulfill({
      status, contentType: "application/json", body: JSON.stringify(o),
      headers: { "access-control-allow-origin": "*" },
    });
    if (url.host === "oauth2.googleapis.com") {
      return json({ sub: "acct1", email: "player@example.com", expires_in: 3600 });
    }
    if (url.host === "accounts.google.com") {
      return route.fulfill({ status: 200, contentType: "text/javascript", body: "" });
    }
    if (url.host !== "www.googleapis.com") return route.abort();
    // DINGBAT_E2E_DRIVE_MS: every Drive call takes this long, as on a slow
    // network or machine, so the app's awaits interleave with what the
    // person does meanwhile.
    const lag = Number(process.env.DINGBAT_E2E_DRIVE_MS || 0);
    if (lag) await new Promise((r) => setTimeout(r, lag));
    const entry = { who, method, path: url.pathname };
    log.push(entry);
    const id = /\/files\/([^/?]+)/.exec(url.pathname)?.[1];
    const upload = url.pathname.startsWith("/upload/");
    const byId = () => files.find((f) => f.id === id);

    if (method === "GET" && !id) return json({ files: files.map(meta) });
    if (method === "GET" && url.searchParams.get("alt") === "media") {
      const f = byId();
      if (!f) return json({ error: "not found" }, 404);
      entry.name = f.name;
      return route.fulfill({ status: 200, contentType: "application/octet-stream", body: f.bytes });
    }
    if (method === "DELETE") {
      const i = files.findIndex((f) => f.id === id);
      if (i >= 0) { entry.name = files[i].name; files.splice(i, 1); }
      return route.fulfill({ status: 204, body: "" });
    }
    const body = req.postDataBuffer() || Buffer.alloc(0);
    const ct = req.headers()["content-type"] || "";
    if (method === "POST") {
      const { meta: m, bytes } = upload ? multipart(ct, body)
        : { meta: JSON.parse(body.toString("utf8")), bytes: Buffer.alloc(0) };
      const t = stamp();
      const f = { id: "f" + idc++, name: m.name, bytes, modifiedTime: t, createdTime: t };
      setProps(f, m.appProperties);
      files.push(f);
      entry.name = f.name;
      return json({ id: f.id, modifiedTime: f.modifiedTime });
    }
    if (method === "PATCH") {
      const f = byId();
      if (!f) return json({ error: "not found" }, 404);
      entry.name = f.name;
      if (upload && url.searchParams.get("uploadType") === "media") {
        f.bytes = body;
      } else if (upload) {
        const { meta: m, bytes } = multipart(ct, body);
        setProps(f, m.appProperties);
        f.bytes = bytes;
      } else {
        const m = JSON.parse(body.toString("utf8"));
        if (m.name) f.name = m.name;
        if (m.appProperties) setProps(f, m.appProperties);
      }
      f.modifiedTime = stamp();
      return json({ id: f.id, name: f.name, modifiedTime: f.modifiedTime });
    }
    return json({ error: "unhandled " + method }, 400);
  };

  const get = (name) => files.find((f) => f.name === name) || null;
  // A session file's header (sessionBundle in index.js): who took it, when.
  const session = (game) => {
    const f = get("stateauto:" + game);
    if (!f) return null;
    const hl = f.bytes.readUInt32LE(8);
    return JSON.parse(f.bytes.subarray(12, 12 + hl).toString("utf8"));
  };
  return { files, log, handle, get, session };
};
