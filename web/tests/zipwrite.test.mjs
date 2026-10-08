// web/zipwrite.js, the export's ZIP writer, read back three ways: by hand
// against APPNOTE's field offsets, by the app's own reader (unzip in
// index.js), and by the system's unzip where there is one. A wrong offset or
// CRC is silent in the app: the download "works" and the file will not open.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync, mkdtempSync, writeFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { spawnSync } from "node:child_process";
import zlib from "node:zlib";
import vm from "node:vm";
import { loadApp } from "./helpers.mjs";

const ctx = { TextEncoder, Blob };
vm.runInNewContext(readFileSync(new URL("../zipwrite.js", import.meta.url), "utf8"), ctx);
const { build, blob, crc32 } = ctx.ZipWrite;

const join8 = (parts) => {
  const out = new Uint8Array(parts.reduce((s, p) => s + p.length, 0));
  let o = 0;
  for (const p of parts) { out.set(p, o); o += p.length; }
  return out;
};

const enc = new TextEncoder();
const FILES = [
  { name: "info.json", data: enc.encode('{"app":"dingbat"}\n') },
  { name: "Pokémon Crystal.sav", data: Uint8Array.from({ length: 32816 }, (_, i) => (i * 7) & 0xff) },
  { name: "dingbat save states/Moments/2026-10-07 11-48.state", data: Uint8Array.of(1, 2, 3) },
  { name: "empty.cht", data: new Uint8Array(0) },
];
const WHEN = new Date(2026, 9, 7, 14, 2, 31); // local time, as the format keeps it

test("CRC-32 matches zlib's", () => {
  for (const f of FILES) assert.equal(crc32(f.data), zlib.crc32(f.data), f.name);
  assert.equal(crc32(enc.encode("123456789")), 0xcbf43926, "the standard check value");
});

test("headers carry what APPNOTE puts where: stored, UTF-8, sizes, DOS time", () => {
  const z = join8(build(FILES, WHEN));
  const dv = new DataView(z.buffer);
  const eocd = z.length - 22;
  assert.equal(dv.getUint32(eocd, true), 0x06054b50);
  assert.equal(dv.getUint16(eocd + 8, true), FILES.length);
  assert.equal(dv.getUint16(eocd + 10, true), FILES.length);
  let p = dv.getUint32(eocd + 16, true);
  assert.equal(p + dv.getUint32(eocd + 12, true), eocd, "the directory ends where the end record starts");
  for (const f of FILES) {
    assert.equal(dv.getUint32(p, true), 0x02014b50);
    assert.equal(dv.getUint16(p + 8, true) & 0x0800, 0x0800, "UTF-8 names");
    assert.equal(dv.getUint16(p + 10, true), 0, "stored");
    assert.equal(dv.getUint16(p + 12, true), (14 << 11) | (2 << 5) | 15, "14:02:30");
    assert.equal(dv.getUint16(p + 14, true), ((2026 - 1980) << 9) | (10 << 5) | 7, "2026-10-07");
    assert.equal(dv.getUint32(p + 16, true), zlib.crc32(f.data));
    assert.equal(dv.getUint32(p + 20, true), f.data.length);
    assert.equal(dv.getUint32(p + 24, true), f.data.length);
    const nameLen = dv.getUint16(p + 28, true);
    assert.equal(new TextDecoder().decode(z.subarray(p + 46, p + 46 + nameLen)), f.name);
    const lo = dv.getUint32(p + 42, true);
    assert.equal(dv.getUint32(lo, true), 0x04034b50, "the offset finds its local header");
    assert.equal(dv.getUint32(lo + 14, true), zlib.crc32(f.data), "local and central agree");
    p += 46 + nameLen;
  }
});

test("the app's own zip reader gets every file back byte for byte", async () => {
  const app = await loadApp();
  const unzip = vm.runInContext("unzip", app.context);
  const z = join8(build(FILES, WHEN));
  const { entries, extract } = await unzip(z.buffer);
  assert.deepEqual(Array.from(entries, (e) => e.name), FILES.map((f) => f.name));
  for (const [i, e] of entries.entries()) {
    assert.deepEqual(new Uint8Array(await extract(e)), FILES[i].data, e.name);
  }
});

test("the system's unzip opens it and finds every CRC right", (t) => {
  const probe = spawnSync("unzip", ["-v"], { encoding: "utf8" });
  if (probe.error) return t.skip("no unzip on this machine");
  const dir = mkdtempSync(join(tmpdir(), "zipwrite-"));
  try {
    const file = join(dir, "export.zip");
    writeFileSync(file, join8(build(FILES, WHEN)));
    const r = spawnSync("unzip", ["-t", file], { encoding: "utf8" });
    assert.equal(r.status, 0, r.stdout + r.stderr);
    assert.match(r.stdout, /No errors detected/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test("blob() is the same bytes, typed as a zip", async () => {
  const b = blob(FILES, WHEN);
  assert.equal(b.type, "application/zip");
  assert.deepEqual(new Uint8Array(await b.arrayBuffer()), join8(build(FILES, WHEN)));
});

test("a date before 1980 is written as the format's first day, not wrapped", () => {
  const z = join8(build([{ name: "a", data: Uint8Array.of(1) }], new Date(1970, 0, 1)));
  const dv = new DataView(z.buffer);
  assert.equal(dv.getUint16(12, true), (1 << 5) | 1);
});
