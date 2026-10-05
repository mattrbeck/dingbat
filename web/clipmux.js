// MP4 (ISO BMFF) muxer for the clip exporter: one H.264 video track and one
// AAC or Opus audio track, written whole from chunks already in memory, with
// moov ahead of mdat so the file plays while it downloads.
//
// Input chunks are WebCodecs EncodedVideoChunk / EncodedAudioChunk outputs
// copied out to { data: Uint8Array, timestamp: µs, duration: µs, key }.
// `description` is the encoder's decoderConfig.description: the avcC record
// for H.264, the AudioSpecificConfig for AAC, and an OpusHead (optional) for
// Opus. An audio encoder starts with `priming` samples of its own (AAC's
// encoder delay, Opus's pre-skip) and pads the end; an edit list trims both,
// leaving exactly `frames` samples from the first real one, or the sound
// runs late against the picture (2112 samples is 44 ms).
//
// Layout, per ISO/IEC 14496-12 (boxes), 14496-14 (esds), 14496-15 (avcC) and
// the Opus-in-ISOBMFF encapsulation (dOps):
//   ftyp | moov { mvhd, trak(video), trak(audio) } | mdat
// Each track's samples go out in about-a-second chunks, interleaved, so a
// player reading front to back never seeks far.
//
// Classic script in the browser (window.ClipMux); node module for tests.
(function (g) {
  const VIDEO_TIMESCALE = 90000;
  const MOVIE_TIMESCALE = 1000;
  const CHUNK_US = 1_000_000;

  const enc = new TextEncoder();

  // A box is [size:u32][type:4cc][payload...]; payloads are arrays of byte
  // arrays, flattened once at the end.
  const u8 = (n) => Uint8Array.of(n & 0xff);
  const u16 = (n) => Uint8Array.of((n >>> 8) & 0xff, n & 0xff);
  const u24 = (n) => Uint8Array.of((n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff);
  const u32 = (n) =>
    Uint8Array.of((n >>> 24) & 0xff, (n >>> 16) & 0xff, (n >>> 8) & 0xff, n & 0xff);
  const zeros = (n) => new Uint8Array(n);
  const str = (s) => enc.encode(s);

  const concat = (parts) => {
    let len = 0;
    for (const p of parts) len += p.length;
    const out = new Uint8Array(len);
    let o = 0;
    for (const p of parts) { out.set(p, o); o += p.length; }
    return out;
  };

  const box = (type, ...parts) => {
    const body = concat(parts.flat(Infinity));
    return concat([u32(8 + body.length), str(type), body]);
  };
  const fullBox = (type, version, flags, ...parts) =>
    box(type, u8(version), u24(flags), ...parts);

  // Unity matrix, as tkhd and mvhd carry it.
  const MATRIX = [u32(0x00010000), u32(0), u32(0), u32(0), u32(0x00010000), u32(0),
                  u32(0), u32(0), u32(0x40000000)];

  const mvhd = (duration, nextTrack) =>
    fullBox("mvhd", 0, 0, u32(0), u32(0), u32(MOVIE_TIMESCALE), u32(duration),
            u32(0x00010000), u16(0x0100), zeros(10), MATRIX, zeros(24), u32(nextTrack));

  const tkhd = (id, duration, audio, w, h) =>
    fullBox("tkhd", 0, 3, u32(0), u32(0), u32(id), u32(0), u32(duration), zeros(8),
            u16(0), u16(0), u16(audio ? 0x0100 : 0), u16(0), MATRIX,
            u32(audio ? 0 : w << 16), u32(audio ? 0 : h << 16));

  const mdhd = (timescale, duration) =>
    fullBox("mdhd", 0, 0, u32(0), u32(0), u32(timescale), u32(duration),
            u16(0x55c4) /* "und" */, u16(0));

  const hdlr = (type, name) =>
    fullBox("hdlr", 0, 0, u32(0), str(type), zeros(12), str(name), zeros(1));

  // One edit: play `duration` (movie timescale) from media time `start`.
  const edts = (duration, start) =>
    box("edts", fullBox("elst", 0, 0, u32(1), u32(duration), u32(start),
                        u16(1), u16(0)));

  // The encoder delay when the encoder does not say: AAC-LC's customary
  // 2112 (1024 + 1088), and for Opus what the OpusHead or dOps carries.
  const AAC_PRIMING = 2112;

  const dinf = () => box("dinf", fullBox("dref", 0, 0, u32(1), fullBox("url ", 0, 1)));

  // --- Sample entries ---

  const avc1 = (w, h, avcC) =>
    box("avc1", zeros(6), u16(1),                    // SampleEntry
        zeros(16), u16(w), u16(h),
        u32(0x00480000), u32(0x00480000), u32(0), u16(1),
        zeros(32), u16(0x0018), u16(0xffff),
        box("avcC", avcC));

  // MPEG-4 descriptors: tag, then a length in 7-bit groups (one byte here;
  // every descriptor this writes is under 128 bytes).
  const desc = (tag, ...parts) => {
    const body = concat(parts.flat(Infinity));
    if (body.length > 127) throw new Error("descriptor too long");
    return concat([u8(tag), u8(body.length), body]);
  };

  // The AudioSpecificConfig. Chromium's AAC encoder hands that over bare;
  // WebKit's hands over a whole ES_Descriptor (tag 3) with it inside, in
  // DecoderSpecificInfo (tag 5).
  const audioSpecificConfig = (d) => {
    if (!d || d.length === 0 || d[0] !== 0x03) return d;
    let found = null;
    const walk = (o, end) => {
      while (o < end && !found) {
        const tag = d[o++];
        let len = 0;
        for (let i = 0; i < 4 && o < end; i++) {
          const b = d[o++];
          len = (len << 7) | (b & 0x7f);
          if (!(b & 0x80)) break;
        }
        const body = o;
        if (tag === 0x05) { found = d.subarray(body, body + len); return; }
        if (tag === 0x03) {
          let p = body + 2;              // ES_ID
          const flags = d[p++];
          if (flags & 0x80) p += 2;      // dependsOn_ES_ID
          if (flags & 0x40) p += 1 + d[p]; // URL
          if (flags & 0x20) p += 2;      // OCR_ES_Id
          walk(p, body + len);
        } else if (tag === 0x04) {
          walk(body + 13, body + len);   // objectType .. avgBitrate
        }
        o = body + len;
      }
    };
    walk(0, d.length);
    if (!found) throw new Error("no AudioSpecificConfig in the ES_Descriptor");
    return found;
  };

  const mp4a = (channels, rate, asc, bitrate) =>
    box("mp4a", zeros(6), u16(1),
        zeros(8), u16(channels), u16(16), u16(0), u16(0), u32(rate << 16),
        fullBox("esds", 0, 0,
          desc(0x03, u16(1), u8(0),                   // ES_ID, flags
            desc(0x04, u8(0x40), u8(0x15), u24(0),    // AAC, audio stream
                 u32(bitrate), u32(bitrate),
                 desc(0x05, audioSpecificConfig(asc))),
            desc(0x06, u8(0x02)))));

  // OpusHead (RFC 7845) is little-endian; dOps carries the same fields
  // big-endian, without the magic.
  const opusPreSkip = (head) => {
    if (head && head.length >= 12 &&
        String.fromCharCode(...head.subarray(0, 8)) === "OpusHead") {
      return head[10] | (head[11] << 8);
    }
    return 312; // libopus's lookahead at 48 kHz, which every encoder here uses
  };

  const opus = (channels, rate, head) =>
    box("Opus", zeros(6), u16(1),
        zeros(8), u16(channels), u16(16), u16(0), u16(0), u32(48000 << 16),
        box("dOps", u8(0), u8(channels), u16(opusPreSkip(head)), u32(rate),
            u16(0), u8(0)));

  // --- Sample tables ---

  // Run-length (count, value) pairs.
  const runs = (values) => {
    const out = [];
    for (const v of values) {
      const last = out[out.length - 1];
      if (last && last[1] === v) last[0]++;
      else out.push([1, v]);
    }
    return out;
  };

  const stts = (deltas) => {
    const r = runs(deltas);
    return fullBox("stts", 0, 0, u32(r.length), r.map(([n, d]) => [u32(n), u32(d)]));
  };

  const stss = (keys) =>
    fullBox("stss", 0, 0, u32(keys.length), keys.map((k) => u32(k)));

  // chunks: per chunk, how many samples. Runs of equal counts share an entry.
  const stsc = (counts) => {
    const entries = [];
    counts.forEach((n, i) => {
      if (!entries.length || entries[entries.length - 1][1] !== n)
        entries.push([i + 1, n]);
    });
    return fullBox("stsc", 0, 0, u32(entries.length),
                   entries.map(([first, n]) => [u32(first), u32(n), u32(1)]));
  };

  const stsz = (sizes) =>
    fullBox("stsz", 0, 0, u32(0), u32(sizes.length), sizes.map((s) => u32(s)));

  const stco = (offsets) =>
    fullBox("stco", 0, 0, u32(offsets.length), offsets.map((o) => u32(o)));

  // Media-timescale deltas from µs timestamps: each sample runs to the next
  // one's start, rounded on the absolute times so the error never piles up.
  const deltasOf = (chunks, timescale) => {
    const at = (us) => Math.round((us * timescale) / 1e6);
    const t0 = chunks.length ? chunks[0].timestamp : 0;
    return chunks.map((c, i) => {
      const next = i + 1 < chunks.length
        ? chunks[i + 1].timestamp
        : c.timestamp + (c.duration || 0);
      return Math.max(1, at(next - t0) - at(c.timestamp - t0));
    });
  };

  // Group a track's samples into ~1 s chunks: [firstSample, count] each.
  const groupChunks = (chunks) => {
    const out = [];
    let start = 0;
    for (let i = 1; i <= chunks.length; i++) {
      if (i === chunks.length ||
          chunks[i].timestamp - chunks[start].timestamp >= CHUNK_US) {
        out.push([start, i - start]);
        start = i;
      }
    }
    return out;
  };

  /**
   * @param {{ video: { width: number, height: number, description: Uint8Array,
   *                    chunks: Array<{data: Uint8Array, timestamp: number,
   *                                   duration?: number, key: boolean}> },
   *           audio?: { codec: "aac" | "opus", sampleRate: number,
   *                     channels: number, bitrate?: number,
   *                     frames?: number, priming?: number,
   *                     description?: Uint8Array | null,
   *                     chunks: Array<{data: Uint8Array, timestamp: number,
   *                                    duration?: number}> } | null }} input
   * @returns {Uint8Array}
   */
  const mp4 = ({ video, audio }) => {
    if (!video || !video.chunks.length) throw new Error("no video");
    if (!video.description) throw new Error("no avcC");
    const tracks = [{
      kind: "video", chunks: video.chunks, timescale: VIDEO_TIMESCALE,
    }];
    if (audio && audio.chunks.length) {
      if (audio.codec === "aac" && !audio.description) throw new Error("no AudioSpecificConfig");
      tracks.push({ kind: "audio", chunks: audio.chunks, timescale: audio.sampleRate });
    }
    for (const t of tracks) {
      t.deltas = deltasOf(t.chunks, t.timescale);
      t.duration = t.deltas.reduce((a, b) => a + b, 0);
      t.groups = groupChunks(t.chunks);
    }

    // Interleave: chunks in order of their first sample's time.
    const order = [];
    tracks.forEach((t, ti) => t.groups.forEach((gr, gi) =>
      order.push({ ti, gi, at: t.chunks[gr[0]].timestamp })));
    order.sort((a, b) => a.at - b.at || a.ti - b.ti);

    let mdatLen = 0;
    for (const t of tracks) for (const c of t.chunks) mdatLen += c.data.length;
    const mdatHeader = 8;
    if (mdatHeader + mdatLen > 0xffffffff) throw new Error("clip too large for one mdat");

    const ftyp = box("ftyp", str("isom"), u32(0x200), str("isom"), str("iso2"),
                     str("avc1"), str("mp41"));

    // moov's size depends on the offsets only through their count, so build
    // it once with placeholders to learn its length, then for real.
    const build = (mdatStart) => {
      let off = mdatStart + mdatHeader;
      const offsets = tracks.map((t) => new Array(t.groups.length));
      for (const { ti, gi } of order) {
        offsets[ti][gi] = off;
        const [first, n] = tracks[ti].groups[gi];
        for (let i = first; i < first + n; i++) off += tracks[ti].chunks[i].data.length;
      }
      const toMovie = (t) => Math.round((t.duration * MOVIE_TIMESCALE) / t.timescale);
      const traks = tracks.map((t, ti) => {
        const id = ti + 1;
        const isVideo = t.kind === "video";
        const entry = isVideo
          ? avc1(video.width, video.height, video.description)
          : audio.codec === "aac"
            ? mp4a(audio.channels, audio.sampleRate, audio.description, audio.bitrate || 128000)
            : opus(audio.channels, audio.sampleRate, audio.description);
        const keys = [];
        if (isVideo) t.chunks.forEach((c, i) => { if (c.key) keys.push(i + 1); });
        const stbl = box("stbl",
          fullBox("stsd", 0, 0, u32(1), entry),
          stts(t.deltas),
          isVideo ? stss(keys) : [],
          stsc(t.groups.map((gr) => gr[1])),
          stsz(t.chunks.map((c) => c.data.length)),
          stco(offsets[ti]));
        const minf = box("minf",
          isVideo ? fullBox("vmhd", 0, 1, zeros(8)) : fullBox("smhd", 0, 0, zeros(4)),
          dinf(), stbl);
        // Audio: from the first real sample, for exactly the samples fed in.
        let edit = [];
        let shown = toMovie(t);
        if (!isVideo) {
          const priming = audio.priming ?? (audio.codec === "aac"
            ? AAC_PRIMING : opusPreSkip(audio.description));
          const real = audio.frames ?? Math.max(0, t.duration - priming);
          shown = Math.round((real * MOVIE_TIMESCALE) / t.timescale);
          edit = edts(shown, priming);
        }
        t.shown = shown;
        return box("trak",
          tkhd(id, shown, !isVideo, video.width, video.height),
          edit,
          box("mdia", mdhd(t.timescale, t.duration),
              hdlr(isVideo ? "vide" : "soun", isVideo ? "Video" : "Sound"), minf));
      });
      const movieDur = Math.max(...tracks.map((t) => t.shown));
      return box("moov", mvhd(movieDur, tracks.length + 1), traks);
    };
    const moovLen = build(0).length;
    const moov = build(ftyp.length + moovLen);
    if (moov.length !== moovLen) throw new Error("moov size moved");

    const out = new Uint8Array(ftyp.length + moov.length + mdatHeader + mdatLen);
    let o = 0;
    out.set(ftyp, o); o += ftyp.length;
    out.set(moov, o); o += moov.length;
    out.set(u32(mdatHeader + mdatLen), o); out.set(str("mdat"), o + 4); o += 8;
    for (const { ti, gi } of order) {
      const [first, n] = tracks[ti].groups[gi];
      for (let i = first; i < first + n; i++) {
        out.set(tracks[ti].chunks[i].data, o);
        o += tracks[ti].chunks[i].data.length;
      }
    }
    return out;
  };

  g.ClipMux = { mp4 };
})(typeof window !== "undefined" ? window : globalThis);
