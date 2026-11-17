// Sync checks on a live link (netplay.js "Sync checks"; tools/formal/
// WebState/LinkSync.lean). Two pages, A the host and B the guest, each a
// helpers.mjs vm context with netplay.js, wired to each other by hand, each
// over a small stand-in for the rollback engine: both games are numbers, a
// frame folds each player's buttons into its game, the friend's buttons are
// predicted until they arrive, and a fingerprint of both games comes out
// every 120 frames once the frame before it is confirmed. A side can be made
// to drift: its copy of the friend's game then goes its own way.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const NET_SOURCE =
  readFileSync(new URL("../sdputil.js", import.meta.url), "utf8") + "\n" +
  readFileSync(new URL("../netplay.js", import.meta.url), "utf8");

const RB_INPUT = 1, RB_HELLO = 0, RB_SYNC = 16, RB_RESYNC = 17, RB_RESYNC_BEGIN = 18;
const EVERY = 120, WINDOW = 12;

const step = (v, bits) => (Math.imul(v ^ bits, 0x9e3779b1) + 0x7f4a7c15) >>> 0;

// The engine (rollback.nim) as far as netplay.js sees it.
const fakeEngine = (local) => {
  const mem = new ArrayBuffer(1 << 16);
  let top = 64;
  const e = {
    base: [0x1111, 0x2222], // the games as last loaded (frame 0)
    head: 0, confirmed: -1, localIn: [], remoteIn: [], known: [],
    nextSync: EVERY, out: [], drift: 0, poke: null, inits: 0, loads: [],
  };
  const bitsFor = (core, f) => {
    if (core === local) return e.localIn[f] ?? 0;
    if (e.known[f]) return e.remoteIn[f];
    return e.confirmed >= 0 ? e.remoteIn[e.confirmed] : 0;
  };
  // Both games before frame f; a drifting side's copy of the friend's game
  // is off by `drift` every frame.
  const before = (f) => {
    let v = [...e.base];
    for (let k = 0; k < f; k++) {
      v = v.map((x, core) => step(x, bitsFor(core, k)));
      if (e.drift) v[1 - local] = (v[1 - local] + e.drift) >>> 0;
      if (e.poke && e.poke === k + 1) v[1 - local] = (v[1 - local] ^ 0x5a) >>> 0;
    }
    return v;
  };
  const flush = () => {
    while (e.nextSync < e.head && e.confirmed >= e.nextSync - 1) {
      const [a, b] = before(e.nextSync);
      e.out.push([e.nextSync, a, b]);
      e.nextSync += EVERY;
    }
  };
  const reconcile = () => {
    let g = e.confirmed;
    while (g + 1 < e.head && e.known[g + 1]) g++;
    e.confirmed = g;
    flush();
  };
  const u32 = () => new Uint32Array(mem);
  e.module = {
    memory: { buffer: mem },
    _malloc: (n) => { const p = top; top += (n + 7) & ~7; return p; },
    _free() {},
    ccall: (name, _r, _t, args) => {
      if (name !== "rollback_init") return 0;
      e.inits++;
      Object.assign(e, { head: 0, confirmed: -1, localIn: [], remoteIn: [], known: [], nextSync: EVERY, out: [], poke: null });
      void args;
      return 1;
    },
    _rollback_tick: (bits) => {
      if (e.head - e.confirmed > WINDOW) return -1;
      e.localIn[e.head] = bits;
      e.head++;
      reconcile();
      return e.head - 1;
    },
    _rollback_feed: (frame, bits) => {
      if (frame < 0 || e.known[frame]) return;
      e.remoteIn[frame] = bits;
      e.known[frame] = true;
      reconcile();
    },
    _rollback_head: () => e.head,
    _rollback_confirmed: () => e.confirmed,
    _rollback_sync_poll: (p) => {
      if (!e.out.length) return 0;
      const [f, a, b] = e.out.shift();
      const w = u32();
      w[p / 4] = f; w[p / 4 + 1] = a; w[p / 4 + 2] = b;
      return 1;
    },
    // Our own game at head, 4 bytes (the real one is pack_state of it).
    _rollback_dump_packed: (player) => {
      const v = before(e.head)[player];
      e.dumped = { head: e.head, confirmed: e.confirmed, v };
      new DataView(mem).setUint32(8, v);
      return 4;
    },
    _rollback_dump_data: () => 8,
    _rollback_load_state: (player, p, len) => {
      if (len !== 4) return 0;
      e.base[player] = new DataView(mem).getUint32(p);
      e.loads.push(player);
      return 1;
    },
    _core_id: (p) => { const w = u32(); w[p / 4] = e.coreHi ?? 0xc0de; w[p / 4 + 1] = 0x0001; },
  };
  e.game = (core) => before(e.head)[core];
  return e;
};

// One side, live as rbStartIfReady leaves it.
const side = async (host, { sync = true, coreHi, built = "2026-11-16T00:00:00Z" } = {}) => {
  const app = await loadApp();
  const { sandbox } = app;
  sandbox.WebSocket = class { constructor() { this.readyState = 0; } send() {} close() {} };
  sandbox.RTCPeerConnection = class { close() {} addEventListener() {} };
  sandbox.BroadcastChannel = class { postMessage() {} addEventListener() {} removeEventListener() {} close() {} };
  sandbox.navigator.onLine = true;
  sandbox.location.hostname = "localhost";
  sandbox.crypto = { getRandomValues: (a) => a };
  for (const id of ["net-stall", "net-away"]) app.document.getElementById(id).hidden = true;
  const eng = fakeEngine(host ? 0 : 1);
  if (coreHi !== undefined) eng.coreHi = coreHi;
  sandbox.Module = eng.module;
  if (!sync) { delete eng.module._rollback_sync_poll; }
  vm.runInContext(NET_SOURCE, app.context, { filename: "web/netplay.js" });
  const out = [];
  sandbox.__sent = out;
  app.runIn(`
    BUILD_TIME = ${JSON.stringify(built)};
    currentRomName = "rom.gba";
    currentOriginalName = "Game.gba";
    window.enterRollbackMode = () => {};
    rollbackMode = true;
    net = { ...makeSession(true), isHost: ${host}, started: true,
            dc: { readyState: "open", send: (b) => __sent.push(b), close() {} },
            rb: { localPlayer: ${host ? 0 : 1}, epoch: 1000, inited: true, resume: null, resumeOk: false,
                  byeIn: false, lastRx: -1, sentFrames: new Int32Array(128),
                  sentBits: new Uint16Array(128), sentCount: 0, reconnecting: false,
                  rsEarly: [], pauseReg: { on: false, n: 0, host: true }, speedReg: { on: false, n: 0, host: true },
                  peerSync: false, peerCore: null, peerBuilt: 0, syncMine: new Map(), syncTheirs: new Map(),
                  syncChecks: 0, syncMismatches: 0, resync: null, resyncGen: 0, resyncs: 0,
                  resyncMs: [], resyncAt: [], resyncWarned: false } };
    0`);
  const take = () => out.splice(0).map((b) => [...(ArrayBuffer.isView(b) ? b : new Uint8Array(b))]);
  const recv = (bytes) => app.runIn(`rbMessage(new Uint8Array([${bytes}]).buffer)`);
  // One display frame: tick unless at the re-sync's stop frame, then the
  // frame hook (index.js's rollback branch).
  const frame = (bits) => {
    if (!app.runIn("rbAtBarrier()")) {
      const f = eng.module._rollback_tick(bits);
      if (f >= 0) app.runIn(`rbSendInput(${f}, ${bits})`);
    }
    app.runIn("rbOnFrame()");
  };
  const rb = (expr) => app.runIn(`(() => { const rb = net?.rb; return rb ? (${expr}) : undefined; })()`);
  return { app, eng, take, recv, frame, rb };
};

// The HELLO each side would send, to the other (only its build fields matter here).
const helloOf = (s) => {
  const own = s.app.runIn("rbOwnBuild()");
  const can = s.app.runIn("rbCanSync()");
  const h = new Uint8Array(34);
  const v = new DataView(h.buffer);
  v.setUint8(0, RB_HELLO);
  v.setUint32(21, own.core[0]); v.setUint32(25, own.core[1]); v.setUint32(29, own.built);
  v.setUint8(33, can ? 1 : 0);
  return [...h];
};

const pair = async (aOpts = {}, bOpts = {}) => {
  const a = await side(true, aOpts), b = await side(false, bOpts);
  // The HELLO's build fields (rbMessage's HELLO branch) without a ROM swap.
  for (const [s, other] of [[a, b], [b, a]]) {
    const h = helloOf(other);
    const len = h.length;
    s.app.runIn(`(() => { const v = new DataView(new Uint8Array([${h}]).buffer);
      const rb = net.rb;
      if (${len} >= RB_HELLO_BUILD_LEN) { rb.peerCore = [v.getUint32(21), v.getUint32(25)];
        rb.peerBuilt = v.getUint32(29); rb.peerSync = (v.getUint8(33) & 1) === 1 && rbCanSync(); } })()`);
  }
  return [a, b];
};

const kinds = (msgs) => msgs.map((m) => m[0]);

// Run both sides `n` frames; what each sends reaches the other `delay`
// frames later (ordered). Returns every message each sent, by kind.
// `delay` frames each way, or `toA` / `toB` for one direction.
// `delay` frames each way, or `toA` / `toB` for one direction; B sits out
// its first `holdB` frames (A runs on to its window).
const run = (a, b, n, { delay = 3, toA = delay, toB = delay, holdB = 0,
                        bitsA = (f) => (f * 7) & 0x3ff, bitsB = (f) => (f * 13) & 0x3ff } = {}) => {
  // In flight between calls too: a run that stops doesn't drop the wire.
  a.wire ??= { q: [[], []], t: 0 };
  const { q } = a.wire;
  const sent = [[], []];
  for (let i = 0; i < n; i++) {
    const t = a.wire.t++;
    a.frame(bitsA(a.eng.head));
    if (i >= holdB) b.frame(bitsB(b.eng.head));
    for (const [i, s, d] of [[0, a, toB], [1, b, toA]]) for (const m of s.take()) { q[i].push([t + d, m]); sent[i].push(m); }
    for (const [i, s] of [[1, a], [0, b]]) {
      while (q[i].length && q[i][0][0] <= t) s.recv(q[i].shift()[1]);
    }
  }
  return sent;
};

test("in step: fingerprints cross every 120 frames and always agree; nothing else is added", async () => {
  const [a, b] = await pair();
  const [sa, sb] = run(a, b, 1000);
  const syncA = sa.filter((m) => m[0] === RB_SYNC), syncB = sb.filter((m) => m[0] === RB_SYNC);
  assert.ok(syncA.length >= 7 && syncA.length === syncB.length, `fingerprints sent: ${syncA.length}, ${syncB.length}`);
  assert.ok(syncA.every((m) => m.length === 14), "each is 14 bytes");
  assert.ok(a.rb("rb.syncChecks") >= 7 && b.rb("rb.syncChecks") >= 7, "and compared");
  assert.equal(a.rb("rb.syncMismatches") + b.rb("rb.syncMismatches"), 0);
  assert.ok(!kinds([...sa, ...sb]).some((k) => k > RB_SYNC), "no re-sync when nothing is wrong");
  // What the checks cost on the wire next to the inputs.
  const bytes = (ms, k) => ms.filter((m) => m[0] === k).reduce((n, m) => n + m.length, 0);
  assert.ok(bytes(sa, RB_SYNC) * 50 < bytes(sa, RB_INPUT), "under 2% of the input bytes");
});

test("a friend that doesn't check is sent nothing new, and a check-less build sends nothing new", async () => {
  const [a, b] = await pair({}, { sync: false });
  assert.equal(a.rb("rb.peerSync"), false);
  const [sa, sb] = run(a, b, 600);
  assert.ok(!kinds(sa).some((k) => k >= RB_SYNC), "A sends B none of 16-20");
  assert.ok(!kinds(sb).some((k) => k >= RB_SYNC), "B can't check and sends none either");
});

test("one side drifts: caught at the next fingerprint, re-synced, own games untouched, in step after", async () => {
  const [a, b] = await pair();
  run(a, b, 200);
  const aOwn = a.eng.game(0), bOwnBefore = b.eng.game(1);
  b.eng.poke = b.eng.head; // B's copy of A's game goes its own way, once
  const [sa, sb] = run(a, b, 400);
  assert.equal(a.rb("rb.syncMismatches"), 1, "A saw the difference");
  assert.equal(b.rb("rb.syncMismatches"), 1, "B did too");
  assert.equal(a.rb("rb.resyncs"), 1);
  assert.equal(b.rb("rb.resyncs"), 1);
  assert.equal(a.eng.inits, 1, "A started over once");
  assert.equal(b.eng.inits, 1);
  assert.ok(kinds(sa).includes(RB_RESYNC_BEGIN) && kinds(sb).includes(RB_RESYNC_BEGIN), "each sent its own game");
  // Each side's own game came through as it was dumped, on both sides.
  assert.equal(a.eng.base[0], a.eng.dumped.v, "A starts again from its own game");
  assert.equal(b.eng.base[0], a.eng.dumped.v, "and so does B's copy of it");
  assert.equal(b.eng.base[1], b.eng.dumped.v, "B starts again from its own game");
  assert.equal(a.eng.base[1], b.eng.dumped.v, "and so does A's copy of it");
  assert.equal(a.eng.dumped.head, b.eng.dumped.head, "both stopped at the same frame");
  assert.equal(a.eng.dumped.confirmed, a.eng.dumped.head - 1, "with every input to it");
  assert.ok(aOwn !== undefined && bOwnBefore !== undefined);
  // In step after: the next fingerprints agree.
  const checks = a.rb("rb.syncChecks");
  run(a, b, 400);
  assert.ok(a.rb("rb.syncChecks") > checks, "checks carry on after");
  assert.equal(a.rb("rb.syncMismatches"), 1, "and agree");
  assert.equal(a.rb("rb.resync"), null);
});

test("both stop at the later of the two proposals, whoever saw it first", async () => {
  const [a, b] = await pair();
  run(a, b, 200);
  b.eng.poke = b.eng.head;
  // B sits out ten frames before the check: from then on A runs a window
  // ahead, so the two propose different stop frames.
  const sent = [[], []];
  const add = (r) => { sent[0].push(...r[0]); sent[1].push(...r[1]); };
  add(run(a, b, 20, { holdB: 10 }));
  add(run(a, b, 400));
  const prop = (ms) => ms.filter((m) => m[0] === RB_RESYNC).map((m) => new DataView(new Uint8Array(m).buffer).getUint32(2));
  const pa = prop(sent[0]), pb = prop(sent[1]);
  assert.equal(pa.length, 1);
  assert.equal(pb.length, 1);
  assert.equal(a.rb("rb.resyncs"), 1);
  assert.equal(b.rb("rb.resyncs"), 1);
  // Both dumped at the later proposal: head = max + 1, every input to it in.
  const target = Math.max(pa[0], pb[0]);
  assert.notEqual(pa[0], pb[0], "the proposals differ (else this proves nothing)");
  assert.equal(a.eng.dumped.head, target + 1);
  assert.equal(b.eng.dumped.head, target + 1);
  assert.equal(a.eng.dumped.confirmed, target);
  assert.equal(b.eng.dumped.confirmed, target);
  assert.ok(target >= 240 + 60, "a proposal is a second past where the side was");
});

test("a copy that keeps drifting: re-synced each time, and after three the players are told why", async () => {
  const [a, b] = await pair({}, { coreHi: 0xbeef, built: "2026-11-01T00:00:00Z" });
  b.eng.drift = 1; // B's core (another version) keeps going its own way
  run(a, b, 2400);
  assert.ok(a.rb("rb.resyncs") >= 3, `re-syncs: ${a.rb("rb.resyncs")}`);
  const toastsA = a.app.toasts.join("\n"), toastsB = b.app.toasts.join("\n");
  assert.match(toastsA, /different versions of dingbat's emulator/);
  assert.match(toastsA, /Your friend's is older/);
  assert.match(toastsB, /Yours is older/);
  const n = a.app.toasts.filter((t) => /drifting apart/.test(t)).length;
  assert.equal(n, 1, "said once");
});

test("the same core drifting again and again reads as a bug, not a version", async () => {
  const [a, b] = await pair();
  b.eng.drift = 1;
  run(a, b, 2400);
  assert.match(a.app.toasts.join("\n"), /keeps drifting out of sync.*report a bug/);
});

test("a link dropping in the middle of a re-sync ends the session", async () => {
  const [a, b] = await pair();
  run(a, b, 200);
  b.eng.poke = b.eng.head;
  run(a, b, 50);
  assert.ok(a.rb("rb.resync") !== null, "re-sync under way");
  a.app.runIn('rbDropped("test", "Lost the connection to your friend")');
  assert.equal(a.app.runIn("net && !net.ending ? 1 : 0"), 0, "the session is over");
  assert.match(a.app.toasts.join("\n") + a.app.runIn("String(document.getElementById('net-status')?.textContent ?? '')"),
    /getting back in sync|Lost the link/);
});

test("a fingerprint from another generation is ignored", async () => {
  const [a, b] = await pair();
  run(a, b, 300);
  const before = a.rb("rb.syncMismatches");
  const m = new Uint8Array(14);
  const v = new DataView(m.buffer);
  v.setUint8(0, RB_SYNC); v.setUint8(1, 7); v.setUint32(2, 240); v.setUint32(6, 1); v.setUint32(10, 2);
  a.recv([...m]);
  run(a, b, 1);
  assert.equal(a.rb("rb.syncMismatches"), before);
  assert.equal(a.rb("rb.resync"), null);
});

test("the side that restarts first waits for the friend's restart before it plays on", async () => {
  // B's state reaches A at once, A's reaches B late: A restarts well before
  // B. Its first new frames' inputs must not reach B while B is still on the
  // old session (which already has those frame numbers and drops them):
  // tools/formal/WebState/LinkSync.lean stale_input_without_wait.
  const [a, b] = await pair();
  run(a, b, 200);
  b.eng.poke = b.eng.head;
  run(a, b, 600, { toA: 1, toB: 25 });
  assert.equal(a.rb("rb.resyncs"), 1, "A finished");
  assert.equal(b.rb("rb.resyncs"), 1, "B finished");
  const before = [a.eng.head, b.eng.head];
  run(a, b, 300, { toA: 1, toB: 25 });
  const after = [a.eng.head, b.eng.head];
  assert.ok(after[0] > before[0] + 200 && after[1] > before[1] + 200,
    `both play on after the re-sync: ${before} -> ${after}`);
  assert.equal(a.rb("rb.syncMismatches"), 1, "and stay in step");
});

test("short, stray and malformed sync messages are ignored; an oversized state ends the session", async () => {
  const [a, b] = await pair();
  run(a, b, 300);
  const before = [a.rb("rb.syncChecks"), a.rb("rb.syncMismatches")];
  // Too short for their kind, a chunk with no begin, a ready for no re-sync.
  for (const m of [[16], [16, 0, 0, 0], [17, 1], [18, 1, 0], [19, 1, 2, 3], [20], [20, 1]]) a.recv(m);
  run(a, b, 300);
  assert.equal(a.rb("rb.syncMismatches"), before[1], "nothing taken for a mismatch");
  assert.ok(a.rb("rb.syncChecks") > before[0], "and the checks go on");
  assert.equal(a.rb("rb.resync"), null);
  // A re-sync whose state claims 4 GB: the session ends, nothing allocated.
  a.app.runIn("rbResyncBegin(net.rb); 0"); // as a mismatch would
  assert.ok(a.rb("rb.resync") !== null, "A is in a re-sync");
  a.recv([18, a.rb("rb.resync.gen"), 0xff, 0xff, 0xff, 0xff]);
  assert.equal(a.app.runIn("net && !net.ending ? 1 : 0"), 0, "the session is over");
  assert.match(a.app.toasts.join("\n") + a.app.runIn("String(document.getElementById('net-status')?.textContent ?? '')"),
    /Couldn't re-sync/);
});

test("the generation counter wraps after 255 re-syncs", async () => {
  const [a, b] = await pair();
  for (const s of [a, b]) s.app.runIn("net.rb.resyncGen = 255; 0");
  run(a, b, 200);
  b.eng.poke = b.eng.head;
  run(a, b, 400);
  assert.equal(a.rb("rb.resyncs"), 1);
  assert.equal(b.rb("rb.resyncs"), 1);
  assert.equal(a.rb("rb.resyncGen"), 0, "255 + 1 is 0 on the wire and here");
  const checks = a.rb("rb.syncChecks");
  run(a, b, 400);
  assert.ok(a.rb("rb.syncChecks") > checks, "generation 0's fingerprints are compared");
  assert.equal(a.rb("rb.syncMismatches"), 1, "and agree");
});

test("a dropped link resumed after a re-sync: the input logs are the new session's", async () => {
  const [a, b] = await pair();
  run(a, b, 200);
  b.eng.poke = b.eng.head;
  run(a, b, 400);
  assert.equal(a.rb("rb.resyncs"), 1);
  run(a, b, 100);
  // The connection drops with inputs in flight both ways; both redial and
  // each tells the other the last input it has (rsAdopt's RESUME).
  a.wire.q = [[], []];
  for (const s of [a, b]) {
    s.app.runIn(`net.rb.resume = { sid: 77, code: "RSABCDEFGHJKLMNP" }; net.rb.resumeOk = true;
      net.rb.reconnecting = true; net.rb.rsDcOpen = true; 0`);
  }
  const resume = (s) => {
    const m = new Uint8Array(10);
    const v = new DataView(m.buffer);
    v.setUint8(0, 13); v.setUint32(1, 77); v.setInt32(5, s.rb("rb.lastRx")); v.setUint8(9, 0);
    return [...m];
  };
  const [ra, rb] = [resume(a), resume(b)];
  assert.ok(a.rb("rb.lastRx") < b.eng.head - 1 && b.rb("rb.lastRx") < a.eng.head - 1, "each missed some");
  b.recv(ra);
  a.recv(rb);
  assert.equal(a.rb("rb.reconnecting"), false, "A resumed");
  assert.equal(b.rb("rb.reconnecting"), false, "B resumed");
  assert.equal(a.app.runIn("net && !net.ending ? 1 : 0"), 1, "no 'gap older than the log'");
  // The resent inputs (now on the wire) are the new session's frames.
  const checks = a.rb("rb.syncChecks");
  run(a, b, 500);
  assert.ok(a.rb("rb.syncChecks") > checks + 2, "checks go on after the resume");
  assert.equal(a.rb("rb.syncMismatches"), 1, "no new difference");
  assert.equal(b.rb("rb.syncMismatches"), 1);
  assert.equal(a.rb("rb.resyncs"), 1, "no second re-sync");
});

test("the GBA BIOS: both on HLE when the two HELLOs name different ones, each its own otherwise", async () => {
  const [a] = await pair();
  const hle = (own, peer) => a.app.runIn(`rbBiosHle({ ownBios: ${JSON.stringify(own)}, peerBios: ${JSON.stringify(peer)} })`);
  const none = { mode: 0, hash: 0 }, real = { mode: 1, hash: 0xb105 };
  assert.equal(hle(none, none), false, "both HLE, no image");
  assert.equal(hle(real, real), false, "the same real BIOS");
  assert.equal(hle(real, none), true, "one real, one HLE");
  assert.equal(hle(none, real), true, "and from the other side");
  assert.equal(hle(real, { mode: 2, hash: 0xb105 }), true, "same image, other mode");
  assert.equal(hle(real, { mode: 1, hash: 0xb106 }), true, "another image");
  assert.equal(hle(real, null), false, "an older friend names none: each its own");
});

test("a re-sync at 2x: the fresh cores are told 2x again", async () => {
  const [a, b] = await pair();
  const turbo = [];
  a.eng.module._wasm_set_turbo = (on) => turbo.push(on);
  a.app.runIn("speed2x = true; 0");
  run(a, b, 200);
  b.eng.poke = b.eng.head;
  turbo.length = 0;
  run(a, b, 400);
  assert.equal(a.rb("rb.resyncs"), 1);
  assert.deepEqual(turbo, [1], "2x pushed into the new cores once, after the restart");
});

test("a re-sync loads our own game first", async () => {
  const [a, b] = await pair();
  run(a, b, 200);
  b.eng.poke = b.eng.head;
  run(a, b, 400);
  assert.equal(b.eng.loads[0], 1, "B (the guest) loaded its own game, core 1, first");
  assert.equal(a.eng.loads[0], 0, "and A its own, core 0");
});
