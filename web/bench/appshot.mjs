// Load a ROM into the real app over CDP, run an expression, screenshot.
// Usage: node appshot.mjs <rom URL> <out.png> [js run after the game starts]
// The tab is the one whose URL contains CDP_MATCH; it is navigated to APP_URL.
import { writeFileSync } from "node:fs";
const PORT = process.env.CDP_PORT || 9222;
const MATCH = process.env.CDP_MATCH || "agent=";
const APP_URL = process.env.APP_URL || "http://127.0.0.1:8797/?agent=settings-cost";
const [rom, out, after = "1"] = process.argv.slice(2);

const targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
const page = targets.find((t) => t.type === "page" && t.url.includes(MATCH));
if (!page) { console.error("no page matching " + MATCH); process.exit(1); }
const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));
let id = 0;
const pending = new Map();
const logs = [];
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) { pending.get(m.id)(m); pending.delete(m.id); }
  else if (m.method === "Runtime.exceptionThrown")
    logs.push("EXCEPTION " + (m.params.exceptionDetails.exception?.description || m.params.exceptionDetails.text));
  else if (m.method === "Runtime.consoleAPICalled" && m.params.type === "error")
    logs.push("console.error " + m.params.args.map((a) => a.value ?? a.description).join(" "));
};
const send = (method, params = {}) => new Promise((res) => {
  const i = ++id; pending.set(i, res); ws.send(JSON.stringify({ id: i, method, params }));
});
const ev = async (expression) => (await send("Runtime.evaluate",
  { expression, awaitPromise: true, returnByValue: true })).result?.result?.value;
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

await send("Runtime.enable");
await send("Page.enable");
await send("DOM.enable");
await send("Page.navigate", { url: APP_URL });
await sleep(4000);
// `rom` is served next to this page; the app takes it as a dropped file.
console.log("load:", JSON.stringify(await ev(`fetch(${JSON.stringify(rom)})
  .then((r) => r.arrayBuffer())
  .then((b) => { handleRomFile(new File([b], ${JSON.stringify(rom.split("/").pop())})); return b.byteLength; })`)));
await sleep(5000);
console.log("after:", JSON.stringify(await ev(after)));
await sleep(3000);
const shot = await send("Page.captureScreenshot", { format: "png" });
writeFileSync(out, Buffer.from(shot.result.data, "base64"));
console.log(logs.length ? logs.join("\n") : "no errors");
ws.close();
