// Drive a *visible* Chrome (normal foreground QoS -> performance cores) over
// CDP and run the dingbat throughput bench. Headless Chrome renderers get
// background QoS on Apple Silicon and land on E-cores, which roughly halves
// the numbers -- so any measurement meant to match what a user sees has to
// come from a real window.
//
// Usage: node cdp.mjs '<js expression returning a JSON-serializable value>'

const PORT = process.env.CDP_PORT || 9222;

const targets = await (await fetch(`http://127.0.0.1:${PORT}/json`)).json();
const page = targets.find((t) => t.type === "page" && t.url.includes("bench.html"));
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

const expr = process.argv[2];
const r = await send("Runtime.evaluate", {
  expression: expr,
  awaitPromise: true,
  returnByValue: true,
  // Long benches block the renderer; don't let CDP give up early.
  timeout: 600000,
});
if (r.result?.exceptionDetails) {
  console.error(JSON.stringify(r.result.exceptionDetails, null, 2));
  process.exit(1);
}
console.log(JSON.stringify(r.result?.result?.value ?? r.result, null, 2));
ws.close();
