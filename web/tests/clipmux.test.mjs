// web/clipmux.js, the clip exporter's MP4 writer, read back box by box. A
// wrong offset or table here is silent in the app: the download "works" and
// the file will not play, or plays with the sound late.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import vm from "node:vm";

const ctx = { TextEncoder };
vm.runInNewContext(readFileSync(new URL("../clipmux.js", import.meta.url), "utf8"), ctx);
const { mp4 } = ctx.ClipMux;

// Boxes as { type, start, size, body }, children of the containers parsed.
const CONTAINERS = new Set(["moov", "trak", "mdia", "minf", "stbl", "dinf", "edts"]);
const parse = (d, o = 0, end = d.length) => {
  const out = [];
  while (o < end) {
    const size = new DataView(d.buffer, d.byteOffset + o).getUint32(0);
    const type = String.fromCharCode(...d.subarray(o + 4, o + 8));
    assert.ok(size >= 8 && o + size <= end, `box ${type} at ${o} has a bad size ${size}`);
    const b = { type, start: o, size, body: d.subarray(o + 8, o + size) };
    if (CONTAINERS.has(type)) b.kids = parse(d, o + 8, o + size);
    out.push(b);
    o += size;
  }
  return out;
};
const find = (boxes, path) => {
  let level = boxes;
  let hit = null;
  for (const t of path.split("/")) {
    hit = level.find((b) => b.type === t);
    assert.ok(hit, "no " + path);
    level = hit.kids || [];
  }
  return hit;
};
const u32s = (body, from = 0) => {
  const dv = new DataView(body.buffer, body.byteOffset);
  const out = [];
  for (let o = from; o + 4 <= body.length; o += 4) out.push(dv.getUint32(o));
  return out;
};

// Each sample's bytes say which sample it is, so an offset that lands
// anywhere else reads as the wrong label.
const sample = (track, i, len = 7) => {
  const d = new Uint8Array(len).fill(i & 0xff);
  d[0] = track === "v" ? 0x56 : 0x41;
  return d;
};
const FRAME_US = 1e6 / (4194304 / 70224);
const videoChunks = (n) => Array.from({ length: n }, (_, i) => ({
  data: sample("v", i, 9 + (i % 3)), timestamp: Math.round(i * FRAME_US),
  duration: Math.round(FRAME_US), key: i % 120 === 0,
}));
const aacChunks = (n) => Array.from({ length: n }, (_, i) => ({
  data: sample("a", i), timestamp: Math.round((i * 1024 * 1e6) / 48000),
  duration: Math.round((1024 * 1e6) / 48000),
}));
const AVCC = Uint8Array.of(1, 0x64, 0, 0x33, 0xff, 0xe1, 0, 0);
const ASC = Uint8Array.of(0x11, 0x90);   // AAC-LC, 48 kHz, stereo

const build = (audio = {}) => mp4({
  video: { width: 960, height: 640, description: AVCC, chunks: videoChunks(150) },
  audio: { codec: "aac", sampleRate: 48000, channels: 2, description: ASC,
           chunks: aacChunks(120), frames: 120 * 1024 - 3000, ...audio },
});

test("ftyp, then moov, then mdat: the file plays while it downloads", () => {
  const boxes = parse(build());
  assert.deepEqual(boxes.map((b) => b.type), ["ftyp", "moov", "mdat"]);
});

test("every chunk offset points at that chunk's own samples", () => {
  const file = build();
  const boxes = parse(file);
  const traks = find(boxes, "moov").kids.filter((b) => b.type === "trak");
  assert.equal(traks.length, 2);
  traks.forEach((trak, ti) => {
    const stbl = find(trak.kids, "mdia/minf/stbl");
    const stco = u32s(find(stbl.kids, "stco").body, 8);
    const stsz = u32s(find(stbl.kids, "stsz").body, 12);
    const stsc = u32s(find(stbl.kids, "stsc").body, 8);
    // Expand stsc (first_chunk, samples_per_chunk, desc) runs per chunk.
    const perChunk = [];
    for (let c = 0; c < stco.length; c++) {
      let n = 0;
      for (let e = 0; e < stsc.length; e += 3) if (stsc[e] <= c + 1) n = stsc[e + 1];
      perChunk.push(n);
    }
    assert.equal(perChunk.reduce((a, b) => a + b, 0), stsz.length, "stsc covers every sample");
    let s = 0;
    stco.forEach((off, c) => {
      for (let k = 0; k < perChunk[c]; k++, s++) {
        const bytes = file.subarray(off, off + stsz[s]);
        assert.equal(bytes[0], ti === 0 ? 0x56 : 0x41, `sample ${s} of track ${ti} is in the other track`);
        assert.equal(bytes[1], s & 0xff, `sample ${s} of track ${ti} is not where stco says`);
        off += stsz[s];
      }
    });
  });
});

test("the two tracks interleave by time rather than one after the other", () => {
  const boxes = parse(build());
  const traks = find(boxes, "moov").kids.filter((b) => b.type === "trak");
  const firsts = traks.map((t) => u32s(find(t.kids, "mdia/minf/stbl/stco").body, 8));
  assert.ok(firsts[0].length > 1 && firsts[1].length > 1, "one chunk a second");
  assert.ok(firsts[1][0] < firsts[0][1], "audio's first second sits before video's second");
});

test("keyframes are listed, and the video runs at the console's rate", () => {
  const boxes = parse(build());
  const vstbl = find(find(boxes, "moov").kids.find((b) => b.type === "trak").kids, "mdia/minf/stbl");
  assert.deepEqual(u32s(find(vstbl.kids, "stss").body, 8), [1, 121]);
  const stts = u32s(find(vstbl.kids, "stts").body, 8);
  let n = 0, dur = 0;
  for (let i = 0; i < stts.length; i += 2) { n += stts[i]; dur += stts[i] * stts[i + 1]; }
  assert.equal(n, 150);
  // 150 frames at 59.7275 fps, in 90 kHz ticks, with no rounding drift.
  assert.ok(Math.abs(dur - (150 * 90000) / (4194304 / 70224)) <= 1, `video lasts ${dur} ticks`);
});

test("an edit list skips the AAC encoder delay and the end padding", () => {
  const boxes = parse(build());
  const atrak = find(boxes, "moov").kids.filter((b) => b.type === "trak")[1];
  const elst = u32s(find(atrak.kids, "edts/elst").body, 4);
  // entry_count, segment_duration (ms), media_time (samples), rate
  assert.equal(elst[0], 1);
  assert.equal(elst[1], Math.round(((120 * 1024 - 3000) * 1000) / 48000));
  assert.equal(elst[2], 2112, "AAC-LC's customary priming, 44 ms of it");
  assert.equal(elst[3], 0x00010000);
  assert.ok(!find(boxes, "moov").kids[1].kids.some((b) => b.type === "edts"),
            "the video starts on its first frame");
});

const esdsASC = (file) => {
  const boxes = parse(file);
  const atrak = find(boxes, "moov").kids.filter((b) => b.type === "trak")[1];
  const stsd = find(atrak.kids, "mdia/minf/stbl/stsd");
  const i = Buffer.from(stsd.body).indexOf("esds");
  const esds = stsd.body.subarray(i + 8);
  const j = esds.indexOf(0x05);       // DecoderSpecificInfo, then its length
  return Array.from(esds.subarray(j + 2, j + 2 + esds[j + 1]));
};

test("the esds carries the encoder's AudioSpecificConfig", () => {
  assert.deepEqual(esdsASC(build()), [0x11, 0x90]);
});

// WebKit's AudioEncoder describes AAC with a whole ES_Descriptor, in the
// four-byte length form; nesting that inside our own made the file unplayable.
test("an ES_Descriptor description is unwrapped to its AudioSpecificConfig", () => {
  const wrapped = Uint8Array.of(
    0x03, 0x80, 0x80, 0x80, 0x22, 0x00, 0x00, 0x00,
    0x04, 0x80, 0x80, 0x80, 0x14, 0x40, 0x14, 0x00, 0x18, 0x00, 0x00, 0x00, 0x00, 0x00,
    0x00, 0x00, 0x00, 0x00,
    0x05, 0x80, 0x80, 0x80, 0x02, 0x11, 0x90,
    0x06, 0x80, 0x80, 0x80, 0x01, 0x02);
  assert.deepEqual(esdsASC(build({ description: wrapped })), [0x11, 0x90]);
});

test("Opus: a dOps with the OpusHead's pre-skip, and the edit list skips it", () => {
  const head = Uint8Array.of(...Buffer.from("OpusHead"), 1, 2, 0x38, 0x01,
                             0x80, 0xbb, 0, 0, 0, 0, 0);
  const file = build({ codec: "opus", description: head,
                       chunks: aacChunks(100).map((c, i) => ({ ...c, timestamp: i * 20000 })) });
  const boxes = parse(file);
  const atrak = find(boxes, "moov").kids.filter((b) => b.type === "trak")[1];
  const stsd = find(atrak.kids, "mdia/minf/stbl/stsd").body;
  const i = Buffer.from(stsd).indexOf("dOps");
  assert.ok(Buffer.from(stsd).indexOf("Opus") > 0, "an Opus sample entry");
  assert.equal((stsd[i + 6] << 8) | stsd[i + 7], 0x138, "pre-skip 312, big-endian");
  assert.equal(u32s(find(atrak.kids, "edts/elst").body, 4)[2], 312);
});
