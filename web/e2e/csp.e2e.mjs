// Each page's Content-Security-Policy (tools/csp.mjs) in a real browser:
// the app, the embeddable player and Google's redirect page each do their
// work with nothing refused, and the app refuses what the policy is for (an
// injected script, an inline handler, a fetch to an address it does not
// list). The other suites count a refusal as a page error on the app page;
// this one covers the two pages no other suite opens.
//
//   node --test e2e/csp.e2e.mjs        # from web/, after the wasm build

import { test, describe, after } from "node:test";
import assert from "node:assert/strict";
import { join } from "node:path";
import { createRequire } from "node:module";
import { serveWeb, builtWeb, WEB } from "./devices.mjs";

const playwright = createRequire(join(WEB, "package.json"))("playwright");
const ENGINES = process.env.DINGBAT_E2E_NO_CHROMIUM ? ["webkit"] : ["chromium", "webkit"];
const channel = process.env.DINGBAT_E2E_CHROMIUM_CHANNEL;
const skip = !builtWeb() ? "web/em.wasm not built (nim c -d:emscripten src/dingbat_wasm.nim)" : false;

let web = null;
const site = async () => (web ??= await serveWeb());
after(() => web?.close());

// A context whose pages report every refusal into `refused`.
const watched = async (browser) => {
  const ctx = await browser.newContext({ viewport: { width: 960, height: 640 } });
  const refused = [];
  await ctx.exposeFunction("__cspRefused", (what) => refused.push(what));
  await ctx.addInitScript(() => document.addEventListener("securitypolicyviolation", (e) =>
    window.__cspRefused(`${e.effectiveDirective} ${e.blockedURI}`)));
  return { ctx, refused };
};

for (const engine of ENGINES) {
  describe(`Content-Security-Policy (${engine})`, { skip }, () => {
    let browser;
    const open = async () => {
      browser ??= await playwright[engine].launch({
        headless: true, ...(engine === "chromium" && channel ? { channel } : {}) });
      return watched(browser);
    };
    after(() => browser?.close());

    test("the app starts, and refuses injected code and unlisted addresses", async () => {
      const { ctx, refused } = await open();
      const page = await ctx.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message));
      await page.goto((await site()).url);
      await page.waitForFunction(() => typeof Module !== "undefined" && runtimeReady, null, { timeout: 60000 });
      assert.deepEqual(refused, [], "nothing the app does is refused");
      const probe = await page.evaluate(async () => {
        window.__ran = 0;
        const s = document.createElement("script");
        s.textContent = "window.__ran |= 1";
        document.body.appendChild(s);
        const d = document.createElement("div");
        d.innerHTML = '<img src="x:" onerror="window.__ran |= 2">';
        document.body.appendChild(d);
        let fetched = true;
        try { await fetch("http://example.com/x", { mode: "no-cors" }); } catch { fetched = false; }
        await new Promise((r) => setTimeout(r, 300));
        return { ran: window.__ran, fetched };
      });
      assert.deepEqual(probe, { ran: 0, fetched: false }, "injected script, handler and fetch all refused");
      assert.ok(refused.length >= 3, "the refusals were reported: " + JSON.stringify(refused));
      assert.deepEqual(errors, []);
      await ctx.close();
    });

    test("a browser that refuses to compile the core is told so, not to check its connection", async () => {
      // As iOS 15 did before the policy carried 'unsafe-eval': the policy
      // with neither keyword that lets wasm compile.
      const { ctx } = await open();
      const page = await ctx.newPage();
      await page.route((url) => url.pathname === "/" || url.pathname === "/index.html", async (route) => {
        const res = await route.fetch();
        const html = (await res.text()).replace(" 'wasm-unsafe-eval' 'unsafe-eval'", "");
        await route.fulfill({ response: res, body: html });
      });
      await page.goto((await site()).url);
      await page.waitForFunction(() => typeof coreLoad !== "undefined" && coreLoad.state === "failed",
        null, { timeout: 60000 });
      await page.evaluate(() => { ensureRuntimeReady(); });
      await page.getByText("This browser blocked the emulator. Try another browser.").waitFor({ timeout: 20000 });
      assert.equal(await page.getByText("Check the connection").count(), 0);
      await ctx.close();
    });

    test("the embeddable player plays its demo, its controls swap, nothing refused", async () => {
      const { ctx, refused } = await open();
      const page = await ctx.newPage();
      const errors = [];
      page.on("pageerror", (e) => errors.push(e.message));
      await page.goto((await site()).url + "embed.html?demo");
      // The core and the demo fetched and started.
      await page.waitForLoadState("networkidle");
      await new Promise((r) => setTimeout(r, 1000));
      const shown = (id) => page.evaluate((i) => getComputedStyle(document.getElementById(i)).display !== "none", id);
      assert.deepEqual([await shown("icon-pause"), await shown("icon-play")], [true, false]);
      await page.click("#pause", { force: true });
      assert.deepEqual([await shown("icon-pause"), await shown("icon-play")], [false, true], "pause swaps the icons");
      const held = await page.evaluate(() =>
        !document.getElementById("canvas").dispatchEvent(new MouseEvent("contextmenu", { bubbles: true, cancelable: true })));
      assert.ok(held, "right-click is kept off the canvas");
      assert.deepEqual(refused, []);
      assert.deepEqual(errors, []);
      await ctx.close();
    });

    test("Google's redirect page hands the code to the page that opened it, nothing refused", async () => {
      const { ctx, refused } = await open();
      const opener = await ctx.newPage();
      await opener.goto((await site()).url + "version.txt");
      await opener.evaluate(() => { window.__got = []; addEventListener("message", (e) => window.__got.push(e.data)); });
      const [popup] = await Promise.all([ctx.waitForEvent("page"),
        opener.evaluate((u) => { window.open(u, "signin", "popup"); },
          (await site()).url + "oauth-callback.html?state=s1&code=c1")]);
      await popup.waitForLoadState().catch(() => {});
      await opener.waitForFunction(() => window.__got.length > 0, null, { timeout: 10000 });
      assert.deepEqual(await opener.evaluate(() => window.__got),
        [{ type: "dingbat-oauth", state: "s1", code: "c1", error: "" }]);
      assert.deepEqual(refused, []);
      await ctx.close();
    });
  });
}
