// The periodic checkpoint's slow half, off the frame's thread (index.js,
// "Checkpoints"). The page copies out the plain state image, the screen and
// the battery file - about 4 ms on a slow phone - and this packs the state,
// signs the battery and encodes the picture, which on the page cost a frame.
//
// Message in:  { id, state, fb, w, h, scale, q, sav } (ArrayBuffers, moved)
// Message out: { id, packed, pic, saveSig } or { id, error }

// pack_state (src/dingbat/common/serialize.nim): the 32-byte header as it
// is, flagged deflated (bit 15 of the u16 at 14), then the rest as zlib.
const HEADER = 32;
const MAGIC = "DGBSTATE";

const pack = async (image) => {
  for (let i = 0; i < MAGIC.length; i++) {
    if (image[i] !== MAGIC.charCodeAt(i)) throw new Error("not a state image");
  }
  if (image[15] & 0x80) return image; // already packed
  const body = new Blob([image.subarray(HEADER)]).stream()
    .pipeThrough(new CompressionStream("deflate"));
  const z = new Uint8Array(await new Response(body).arrayBuffer());
  const out = new Uint8Array(HEADER + z.length);
  out.set(image.subarray(0, HEADER));
  out[15] |= 0x80;
  out.set(z, HEADER);
  return out;
};

// saveSignature in index.js, byte for byte (FNV-1a and the length).
const signature = (data) => {
  let h = 0x811c9dc5;
  for (let i = 0; i < data.length; i++) { h ^= data[i]; h = Math.imul(h, 0x01000193) >>> 0; }
  return h + ":" + data.length;
};

// frameBlobFromFb in index.js, on OffscreenCanvas: the screen scaled by
// whole pixels, as a JPEG. Null where the worker has no 2D canvas (the page
// draws it instead).
const picture = async (fb, w, h, scale, q) => {
  if (typeof OffscreenCanvas !== "function") return null;
  const full = new OffscreenCanvas(w, h);
  const fctx = full.getContext("2d");
  if (!fctx) return null;
  const img = fctx.createImageData(w, h);
  img.data.set(fb);
  for (let i = 3; i < img.data.length; i += 4) img.data[i] = 255; // fb alpha is not meaningful
  fctx.putImageData(img, 0, 0);
  const out = new OffscreenCanvas(w * scale, h * scale);
  const octx = out.getContext("2d");
  if (!octx || typeof out.convertToBlob !== "function") return null;
  octx.imageSmoothingEnabled = false;
  octx.drawImage(full, 0, 0, out.width, out.height);
  return out.convertToBlob({ type: "image/jpeg", quality: q });
};

self.onmessage = async (e) => {
  const { id, state, fb, w, h, scale, q, sav } = e.data;
  try {
    const packed = await pack(new Uint8Array(state));
    const saveSig = sav && sav.byteLength ? signature(new Uint8Array(sav)) : null;
    let pic = null;
    if (fb) {
      try { pic = await picture(new Uint8Array(fb), w, h, scale, q); } catch { pic = null; }
    }
    self.postMessage({ id, packed, pic, saveSig, picTried: !!fb }, [packed.buffer]);
  } catch (err) {
    self.postMessage({ id, error: String(err && err.message || err) });
  }
};
