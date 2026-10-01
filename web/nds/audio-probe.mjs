// Headless check of the DS page's audio path: node web/nds/audio-probe.mjs URL
// (serve web/ first, e.g. python3 -m http.server 8791 -d web, and pass
// http://localhost:8791/nds.html?rom=nds/demos/snd_suite.nds).
//
// Chromium runs muted (--mute-audio): nothing is heard; the AudioContext
// clock still runs. The probe reads NdsAudio.stats() (ring underruns /
// overruns, fill) through four phases and prints one line per phase:
//   steady   plain requestAnimationFrame
//   jitter   each rAF callback delayed by a random 0-12 ms busy wait, plus a
//            40 ms stall every ~2 s (GC-like)
//   slow     every callback busy-waits 14 ms (a device near its limit)
//   hidden   the tab "hidden" for 3 s (rAF stops, visibilitychange) and back,
//            three times
// Each phase reports audio-clock seconds, frames sent per audio second
// (should be 32728.5), underruns, overruns and the fill range in ms.
// Exit status 1 when a phase other than `slow` underran.
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
let pw;
try { pw = require('playwright'); }
catch { pw = require(process.env.PLAYWRIGHT_PATH || '../../../web/node_modules/playwright'); }

const url = process.argv[2];
const SECS = Number(process.env.PHASE_SECS || 8);
const browser = await pw.chromium.launch({
  args: ['--mute-audio', '--autoplay-policy=no-user-gesture-required'] });
const page = await browser.newPage();
page.on('pageerror', e => console.log('pageerror:', e.message));
await page.addInitScript(() => {
  // rAF wrapper: busy waits / stalls / hiding driven by window.__probe.
  const raf = window.requestAnimationFrame.bind(window);
  const P = window.__probe = { mode: 'steady', hidden: false, held: [] };
  const spin = ms => { const e = performance.now() + ms; while (performance.now() < e) {} };
  let lastStall = 0;
  window.requestAnimationFrame = cb => raf(t => {
    if (P.hidden) { P.held.push(cb); return; }
    if (P.mode === 'jitter') {
      spin(Math.random() * 12);
      if (t - lastStall > 2000) { lastStall = t; spin(40); }
    } else if (P.mode === 'slow') spin(14);
    cb(performance.now());
  });
  Object.defineProperty(document, 'hidden', { get: () => P.hidden });
  P.setHidden = h => {
    P.hidden = h;
    document.dispatchEvent(new Event('visibilitychange'));
    if (!h) { const held = P.held; P.held = []; held.forEach(cb => raf(cb)); }
  };
});
await page.goto(url);
await page.waitForFunction(() => /frame/.test(document.querySelector('#status').textContent));
await page.mouse.click(5, 5);                       // the gesture that starts audio
await page.waitForFunction(() => NdsAudio.stats().state === 'running');
await page.waitForTimeout(1000);

const rate = 33513982 / 1024;
let bad = false;
async function phase(name, body) {
  const a = await page.evaluate(() => ({ s: NdsAudio.stats(), t: performance.now() }));
  await page.evaluate(() => { NdsAudio.stats(); });
  const fills = [];
  const poll = setInterval(async () => {
    try { const f = await page.evaluate(() => NdsAudio.fillFrames()); if (f !== null) fills.push(f); } catch {}
  }, 50);
  await body();
  clearInterval(poll);
  const b = await page.evaluate(() => ({ s: NdsAudio.stats(), t: performance.now(),
                                         ct: 0 }));
  const secs = (b.t - a.t) / 1000;
  const under = b.s.underruns - a.s.underruns, over = b.s.overruns - a.s.overruns;
  const ms = f => (f / rate * 1000).toFixed(1);
  console.log(`${name.padEnd(7)} ${secs.toFixed(1)} s  frames/s ${((b.s.sent - a.s.sent) / secs).toFixed(1)}` +
    `  underruns ${under}  overruns ${over}  fill ${ms(Math.min(...fills))}..${ms(Math.max(...fills))} ms` +
    `  ring min ${b.s.minFill === null ? '-' : ms(b.s.minFill)} ms  ctx ${b.s.rate} Hz`);
  if (name !== 'slow' && under > 0) bad = true;
}
const setMode = m => page.evaluate(m => { window.__probe.mode = m; }, m);
await phase('steady', async () => { await setMode('steady'); await page.waitForTimeout(SECS * 1000); });
await phase('jitter', async () => { await setMode('jitter'); await page.waitForTimeout(SECS * 1000); });
await phase('slow', async () => { await setMode('slow'); await page.waitForTimeout(SECS * 1000); });
await phase('hidden', async () => {
  await setMode('steady');
  for (let i = 0; i < 3; i++) {
    await page.evaluate(() => window.__probe.setHidden(true));
    await page.waitForTimeout(3000);
    await page.evaluate(() => window.__probe.setHidden(false));
    await page.waitForTimeout(2000);
  }
});
console.log('status:', await page.textContent('#status'));
await browser.close();
process.exit(bad ? 1 : 0);
