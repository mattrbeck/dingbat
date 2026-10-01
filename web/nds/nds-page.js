// DS prototype page: loads the wasm core (nds.js), feeds it a ROM plus
// optional BIOS/firmware, and blits the two 256x192 RGBA framebuffers.
'use strict';

var Module = {
  onRuntimeInitialized() { NdsPage.ready(); },
};

const NdsPage = (() => {
  const W = 256, H = 192;
  const top = document.getElementById('top').getContext('2d');
  const bottom = document.getElementById('bottom').getContext('2d');
  const imgTop = top.createImageData(W, H);
  const imgBottom = bottom.createImageData(W, H);
  const statusEl = document.getElementById('status');
  let loaded = false, paused = false, romBytes = null, last = 0, acc = 0;
  const FRAME_MS = 1000 / 59.8261;

  // BIOS/firmware live in localStorage (base64) so a reload keeps them.
  const BIOS_NAMES = ['bios9.bin', 'bios7.bin', 'firmware.bin'];
  function loadStored(name) {
    try {
      const s = localStorage.getItem('nds:' + name);
      if (!s) return null;
      return Uint8Array.from(atob(s), c => c.charCodeAt(0));
    } catch (e) { return null; }
  }
  function store(name, bytes) {
    try {
      let s = '';
      for (let i = 0; i < bytes.length; i += 0x8000)
        s += String.fromCharCode.apply(null, bytes.subarray(i, i + 0x8000));
      localStorage.setItem('nds:' + name, btoa(s));
    } catch (e) { console.warn('could not remember', name, e); }
  }

  function toHeap(bytes) {
    if (!bytes || !bytes.length) return [0, 0];
    const p = Module._malloc(bytes.length);
    Module.HEAPU8.set(bytes, p);
    return [p, bytes.length];
  }

  function boot(bytes) {
    romBytes = bytes;
    const args = [bytes, ...BIOS_NAMES.map(loadStored)].map(toHeap);
    Module._nds_load(...args.flat());
    args.forEach(([p]) => p && Module._free(p));
    loaded = true;
  }

  function blit() {
    const t = Module._nds_fb_top(), b = Module._nds_fb_bottom();
    imgTop.data.set(Module.HEAPU8.subarray(t, t + W * H * 4));
    imgBottom.data.set(Module.HEAPU8.subarray(b, b + W * H * 4));
    top.putImageData(imgTop, 0, 0);
    bottom.putImageData(imgBottom, 0, 0);
  }

  function frame() {
    Module._nds_run_frame();
    blit();
    statusEl.textContent = Module.UTF8ToString(Module._nds_status());
  }

  function tick(now) {
    if (loaded && !paused) {
      acc += Math.min(100, now - last);
      let n = 0;
      while (acc >= FRAME_MS && n < 3) { frame(); acc -= FRAME_MS; n++; }
    }
    last = now;
    requestAnimationFrame(tick);
  }

  // Buttons: ids follow NdsButton in src/dingbat/nds/io/input.nim
  const KEYS = { KeyX: 0, KeyZ: 1, ShiftLeft: 2, ShiftRight: 2, Enter: 3, ArrowRight: 4,
                 ArrowLeft: 5, ArrowUp: 6, ArrowDown: 7, KeyW: 8, KeyQ: 9, KeyS: 10, KeyA: 11 };
  function key(e, down) {
    if (!(e.code in KEYS) || !loaded) return;
    Module._nds_set_button(KEYS[e.code], down ? 1 : 0);
    e.preventDefault();
  }
  addEventListener('keydown', e => key(e, true));
  addEventListener('keyup', e => key(e, false));

  const bc = document.getElementById('bottom');
  function touch(e, down) {
    if (!loaded) return;
    const r = bc.getBoundingClientRect();
    const x = Math.floor((e.clientX - r.left) * W / r.width);
    const y = Math.floor((e.clientY - r.top) * H / r.height);
    Module._nds_set_touch(x, y, down ? 1 : 0);
  }
  bc.addEventListener('pointerdown', e => { bc.setPointerCapture(e.pointerId); touch(e, true); });
  bc.addEventListener('pointermove', e => { if (e.buttons) touch(e, true); });
  bc.addEventListener('pointerup', e => touch(e, false));

  document.getElementById('rom').addEventListener('change', async e => {
    const f = e.target.files[0];
    if (f) boot(new Uint8Array(await f.arrayBuffer()));
  });
  document.getElementById('bios').addEventListener('change', async e => {
    for (const f of e.target.files) {
      const name = f.name.toLowerCase();
      const bytes = new Uint8Array(await f.arrayBuffer());
      const kind = BIOS_NAMES.find(n => name.includes(n.split('.')[0])) ||
        (bytes.length === 4096 ? 'bios9.bin' : bytes.length === 16384 ? 'bios7.bin' :
         bytes.length === 262144 ? 'firmware.bin' : null);
      if (kind) store(kind, bytes);
    }
    if (romBytes) boot(romBytes);
  });
  document.getElementById('demo').addEventListener('change', async e => {
    if (!e.target.value) return;
    const r = await fetch(e.target.value);
    boot(new Uint8Array(await r.arrayBuffer()));
  });
  document.getElementById('pause').addEventListener('click', e => {
    paused = !paused;
    e.target.textContent = paused ? 'Resume' : 'Pause';
  });
  document.getElementById('step').addEventListener('click', () => { if (loaded) frame(); });
  document.getElementById('reset').addEventListener('click', () => { if (romBytes) boot(romBytes); });

  return {
    ready() {
      const have = BIOS_NAMES.filter(loadStored);
      statusEl.textContent = 'core ready. BIOS/firmware stored: ' + (have.join(', ') || 'none');
      requestAnimationFrame(t => { last = t; tick(t); });
      const demo = new URLSearchParams(location.search).get('rom');
      if (demo) fetch(demo).then(r => r.arrayBuffer()).then(b => boot(new Uint8Array(b)));
    },
  };
})();
