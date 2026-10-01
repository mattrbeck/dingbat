// Ambient-glow screenshots from the real app, for a before/after gallery.
// Each shot: load the ROM, turn the glow on, freeze emulation (loop_tick
// stubbed, so the app keeps presenting and sampling one frame), load a
// state, step `frames` more, let the glow settle, capture. The same frame
// on any build of the same core, so two builds' shots differ only in how
// they draw the glow.
//
// Usage: node glowshots.mjs <jobs.json> <out dir>
//   jobs: [{ base: "http://127.0.0.1:8798", tag: "before", rom: "glow/X.gba",
//            state: "glow/X_a.state", frames: 0, name: "x_a",
//            viewport: { width, height, deviceScaleFactor, mobile } }]
import { readFileSync, writeFileSync, mkdirSync } from "node:fs";
const PORT = process.env.CDP_PORT || 9222;
const MATCH = process.env.CDP_MATCH || "agent=";
const [jobsPath, outDir] = process.argv.slice(2);
const jobs = JSON.parse(readFileSync(jobsPath, "utf8"));
mkdirSync(outDir, { recursive: true });

const targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
const page = targets.find((t) => t.type === "page" && t.url.includes(MATCH));
if (!page) { console.error("no page matching " + MATCH); process.exit(1); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const pending = new Map();
const errors = [];
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  else if (m.method === "Runtime.exceptionThrown")
    errors.push(m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text);
};
const send = (method, params = {}) => new Promise((res) => {
  const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params }));
});
const ev = async (expression) => {
  const r = await send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true });
  if (r.result?.exceptionDetails) throw new Error(JSON.stringify(r.result.exceptionDetails).slice(0, 400));
  return r.result?.result?.value;
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
await send("Runtime.enable");

for (const j of jobs) {
  const vp = j.viewport || { width: 1600, height: 900, deviceScaleFactor: 1, mobile: false };
  await send("Emulation.setDeviceMetricsOverride", vp);
  await send("Page.navigate", { url: `${j.base}/?agent=settings-cost` });
  await sleep(4000);
  await ev(`fetch(${JSON.stringify(j.base + "/bench/" + j.rom)})
    .then((r) => r.arrayBuffer())
    .then((b) => { handleRomFile(new File([b], ${JSON.stringify(j.rom.split("/").pop())})); return b.byteLength; })`);
  await sleep(5000);
  const info = await ev(`(async () => {
    const t = document.getElementById("ambient-glow-toggle");
    if (!t.checked) { t.checked = true; t.dispatchEvent(new Event("change")); }
    Module._loop_tick = () => {};
    Module._runahead_tick = () => {};
    const u = new Uint8Array(await fetch(${JSON.stringify(j.base + "/bench/" + j.state)}).then((r) => r.arrayBuffer()));
    const p = Module._malloc(u.length);
    new Uint8Array(Module.memory.buffer, p, u.length).set(u);
    const ok = Module._wasm_load_state(p, u.length, 0);
    Module._free(p);
    if (${j.frames || 0} > 0) Module._benchFrames(${j.frames || 0});
    if (Module._clearAudioBuffer) Module._clearAudioBuffer();
    presentDirty = true;
    glowFresh = true;
    const g = document.getElementById("glow-canvas");
    return { ok, running: document.body.classList.contains("running"), glow: !g.hidden,
             grid: [g.width, g.height] };
  })()`);
  await sleep(2500);   // the glow samples at 10 Hz and settles on the held frame
  const shot = await send("Page.captureScreenshot", { format: "jpeg", quality: 88 });
  const file = `${outDir}/${j.name}_${j.tag}.jpg`;
  writeFileSync(file, Buffer.from(shot.result.data, "base64"));
  console.log(j.name, j.tag, JSON.stringify(info));
}
await send("Emulation.clearDeviceMetricsOverride");
await send("Page.navigate", { url: "about:blank" });
console.log(errors.length ? "page errors:\n" + errors.join("\n") : "no page errors");
ws.close();
