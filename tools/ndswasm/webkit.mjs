// node webkit.mjs PORT JS WORKLOAD BLOCKS(0|1) [extra,comma,args]
// Headless Playwright WebKit (JavaScriptCore), muted (ndsrun makes no
// sound), one page: page.html from server.py. Playwright from web/'s
// node_modules ($NDSWASM_WEB: the checkout's web/ directory).
import { createRequire } from 'node:module';
const require = createRequire(`${process.env.NDSWASM_WEB}/package.json`);
const { webkit } = require('playwright');
const [port, js, wl, blocks, extra] = process.argv.slice(2);
const browser = await webkit.launch({ headless: true });
const page = await browser.newPage();
const done = new Promise((ok) => {
  page.on('console', (m) => {
    const t = m.text();
    if (t === 'DONE') ok();
    else console.log(t);
  });
});
page.on('pageerror', (e) => console.log('PAGEERROR ' + e));
const u = `http://127.0.0.1:${port}/page.html?js=${js}&wl=${wl}&blocks=${blocks}` +
  (extra ? `&extra=${encodeURIComponent(extra)}` : '');
await page.goto(u);
await done;
await browser.close();
