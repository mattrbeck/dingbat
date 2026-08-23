// Drive a visible Chrome over CDP and run the throughput bench. Headless
// renderers get background QoS on Apple Silicon (E-cores, roughly half the
// numbers), so user-matching measurements need a real window.
//
// Usage: node cdp.mjs '<js expression returning a JSON-serializable value>'

const PORT = process.env.CDP_PORT || 9222;

const targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
const page = targets.find((t) => t.type === "page" && t.url.includes(process.env.CDP_MATCH || "bench.html"));
if (!page) {
  console.error("no bench.html target; open it in the debug Chrome first");
  console.error(targets.map((t) => `${t.type} ${t.url}`).join("\n"));
  process.exit(1);
}

const ws = new WebSocket(page.webSocketDebuggerUrl);
await new Promise((r) => (ws.onopen = r));

let id = 0;
const pending = new Map();
ws.onmessage = (e) => {
  const m = JSON.parse(e.data);
  if (m.id && pending.has(m.id)) {
    pending.get(m.id)(m);
    pending.delete(m.id);
  }
};
const send = (method, params) =>
  new Promise((res) => {
    const i = ++id;
    pending.set(i, res);
    ws.send(JSON.stringify({ id: i, method, params }));
  });

// CDP_THROTTLE=<n>: Emulation.setCPUThrottlingRate, a stand-in for older hardware.
const throttle = Number(process.env.CDP_THROTTLE || 1);
if (throttle !== 1) await send("Emulation.setCPUThrottlingRate", { rate: throttle });

const expr = process.argv[2];
const r = await send("Runtime.evaluate", {
  expression: expr,
  awaitPromise: true,
  returnByValue: true,
  // Long benches block the renderer.
  timeout: 600000,
});
if (r.result?.exceptionDetails) {
  console.error(JSON.stringify(r.result.exceptionDetails, null, 2));
  process.exit(1);
}
console.log(JSON.stringify(r.result?.result?.value ?? r.result, null, 2));
ws.close();
