// GPU-process cost of a page scene, from a Chrome trace: starts the scene
// with the glow off, as the old CSS and as the composed bitmap in turn
// (settingsGlowScene), traces each for SECONDS, and sums the
// busy time of the GPU process's threads (task durations from the toplevel
// category). The difference is what the compositor pays for the effect.
//
// Usage: node glowtrace.mjs [seconds] [reps]   (page: settings.html, scene loaded)
const PORT = process.env.CDP_PORT || 9222;
const MATCH = process.env.CDP_MATCH || "settings.html";
const SECONDS = Number(process.argv[2] || 5);
const REPS = Number(process.argv[3] || 3);

const ver = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json();
const targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
const page = targets.find((t) => t.type === "page" && t.url.includes(MATCH));
if (!page) { console.error("no page matching " + MATCH); process.exit(1); }

const connect = async (url) => {
  const ws = new WebSocket(url);
  await new Promise((r) => (ws.onopen = r));
  let id = 0;
  const pending = new Map();
  const listeners = [];
  ws.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
    else listeners.forEach((f) => f(m));
  };
  const send = (method, params = {}) => new Promise((res) => {
    const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params }));
  });
  return { ws, send, on: (f) => listeners.push(f) };
};

const browser = await connect(ver.webSocketDebuggerUrl);
const pg = await connect(page.webSocketDebuggerUrl);
const evalPage = (expr) => pg.send("Runtime.evaluate", { expression: expr, awaitPromise: true, returnByValue: true });

const traceOnce = async () => {
  const events = [];
  let done;
  const finished = new Promise((r) => (done = r));
  browser.on((m) => {
    if (m.method === "Tracing.dataCollected") events.push(...m.params.value);
    if (m.method === "Tracing.tracingComplete") done();
  });
  await browser.send("Tracing.start", {
    transferMode: "ReportEvents",
    traceConfig: { includedCategories: ["toplevel", "__metadata"], recordMode: "recordAsMuchAsPossible" },
  });
  await new Promise((r) => setTimeout(r, SECONDS * 1000));
  await browser.send("Tracing.end");
  await finished;
  // pid -> process name, (pid,tid) -> thread name
  const pname = new Map(), tname = new Map();
  for (const e of events) {
    if (e.ph !== "M") continue;
    if (e.name === "process_name") pname.set(e.pid, e.args.name);
    if (e.name === "thread_name") tname.set(e.pid + ":" + e.tid, e.args.name);
  }
  // Busy ms per GPU-process thread: top-level complete events only (nested
  // tasks would double count), so keep events not contained in another on
  // the same thread.
  const byThread = new Map();
  for (const e of events) {
    if (e.ph !== "X" || !e.dur) continue;
    if (!/gpu/i.test(pname.get(e.pid) || "")) continue;
    const k = e.pid + ":" + e.tid;
    if (!byThread.has(k)) byThread.set(k, []);
    byThread.get(k).push(e);
  }
  const out = {};
  for (const [k, evs] of byThread) {
    evs.sort((a, b) => a.ts - b.ts);
    let end = -1, busy = 0;
    for (const e of evs) {
      if (e.ts >= end) { busy += e.dur; end = e.ts + e.dur; }
      else if (e.ts + e.dur > end) { busy += e.ts + e.dur - end; end = e.ts + e.dur; }
    }
    out[tname.get(k) || k] = busy / 1000 / SECONDS; // ms of busy per wall second
  }
  return out;
};

const MODES = ["off", "css", "composed"];
const results = Object.fromEntries(MODES.map((m) => [m, []]));
for (let r = 0; r < REPS; r++) {
  for (const mode of MODES) {
    await evalPage(`window.settingsGlowScene(${JSON.stringify(mode)})`);
    await new Promise((x) => setTimeout(x, 1000)); // settle
    results[mode].push(await traceOnce());
  }
}
await evalPage("window.settingsSceneStop()");
const med = (a) => { const s = [...a].sort((x, y) => x - y); return s[(s.length / 2) | 0]; };
const threads = new Set(MODES.flatMap((m) => results[m].flatMap((o) => Object.keys(o))));
const rows = [...threads].map((t) => {
  const v = Object.fromEntries(MODES.map((m) => [m, med(results[m].map((o) => o[t] || 0))]));
  const row = { thread: t };
  for (const m of MODES) row[m + "MsPerSec"] = +v[m].toFixed(2);
  for (const m of MODES.slice(1)) row[m + "AddedMsPerFrame"] = +((v[m] - v.off) / 60).toFixed(4);
  return row;
}).filter((r) => MODES.some((m) => r[m + "MsPerSec"] > 0.5));
console.log(JSON.stringify(rows, null, 2));
browser.ws.close(); pg.ws.close();
