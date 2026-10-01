// Screenshot the DS dev page headlessly: node web/nds/shot.mjs URL OUT.png
// (Playwright from web/node_modules; serve web/ first, e.g. on :8791.)
// Optional env: BIOS_DIR (feeds bios9/bios7/firmware .bin to the BIOS
// picker), ROM (a local .nds fed to the ROM picker), WAIT_MS.
import { createRequire } from 'module';
import path from 'path';
const require = createRequire(import.meta.url);
let pw;
try { pw = require('playwright'); }
catch { pw = require(process.env.PLAYWRIGHT_PATH || '../../../web/node_modules/playwright'); }
const [url, out] = process.argv.slice(2);
const browser = await pw.chromium.launch({ args: ['--mute-audio'] });
const page = await browser.newPage({ viewport: { width: 900, height: 900 } });
page.on('console', m => console.log('console:', m.text()));
page.on('pageerror', e => console.log('pageerror:', e.message));
await page.goto(url);
await page.waitForFunction(() => /core ready|frame/.test(document.querySelector('#status').textContent));
if (process.env.BIOS_DIR) {
  await page.setInputFiles('#bios', ['bios9.bin', 'bios7.bin', 'firmware.bin']
    .map(f => path.join(process.env.BIOS_DIR, f)));
}
if (process.env.ROM) await page.setInputFiles('#rom', process.env.ROM);
await page.waitForTimeout(Number(process.env.WAIT_MS || 2000));
console.log('status:', await page.textContent('#status'));
await page.screenshot({ path: out });
await browser.close();
