// The Game Boy shade palette (Settings → General).
//
// Three sources of shades — the core's own, the app theme, and four colours the
// user picked — are ONE setting with a mode, so the interesting properties are
// (a) exactly one source is ever in force, (b) the mode and the custom colours
// both survive a reload, (c) the palette's own Reset undoes the palette and
// NOTHING else, and (d) the whole thing stays off for colour games.
//
// The substitution itself happens in the WebGL presenter's shader
// (web/glpresent.js); there is no GL context in this harness, so what is pinned
// here is the decision — which four colours, and whether they apply at all.

import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, eq, settle } from "./helpers.mjs";

// --- contrast, for the "a ramp must not collapse" test ----------------------
const relLum = (hex) => {
  const [r, g, b] = [1, 3, 5].map((i) => {
    let v = parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
};
const contrast = (a, b) => {
  const [x, y] = [relLum(a), relLum(b)];
  return (Math.max(x, y) + 0.05) / (Math.min(x, y) + 0.05);
};

// --- CIEDE2000, for the "a ramp must not vibrate" test ----------------------
// Contrast alone cannot see the failure it is paired with here: two shades can
// darken correctly, be far apart in luminance, and still be a different HUE —
// and a game that dithers them against each other pixel by pixel then shimmers
// instead of blending. Perceptual difference is what notices that.
const toLab = (hex) => {
  const [R, G, B] = [1, 3, 5].map((i) => {
    const v = parseInt(hex.slice(i, i + 2), 16) / 255;
    return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
  });
  // D65 white point.
  let x = (0.4124 * R + 0.3576 * G + 0.1805 * B) / 0.95047;
  let y = 0.2126 * R + 0.7152 * G + 0.0722 * B;
  let z = (0.0193 * R + 0.1192 * G + 0.9505 * B) / 1.08883;
  const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);
  [x, y, z] = [f(x), f(y), f(z)];
  return [116 * y - 16, 500 * (x - y), 200 * (y - z)];
};
const deltaE2000 = (c1, c2) => {
  const [L1, a1, b1] = toLab(c1), [L2, a2, b2] = toLab(c2);
  const rad = Math.PI / 180, deg = 180 / Math.PI;
  const Cb = (Math.hypot(a1, b1) + Math.hypot(a2, b2)) / 2;
  const G = 0.5 * (1 - Math.sqrt(Cb ** 7 / (Cb ** 7 + 25 ** 7)));
  const A1 = (1 + G) * a1, A2 = (1 + G) * a2;
  const Cp1 = Math.hypot(A1, b1), Cp2 = Math.hypot(A2, b2);
  const hue = (a, b) => { const x = Math.atan2(b, a) * deg; return x < 0 ? x + 360 : x; };
  const h1 = Cp1 === 0 ? 0 : hue(A1, b1), h2 = Cp2 === 0 ? 0 : hue(A2, b2);
  const dL = L2 - L1, dC = Cp2 - Cp1;
  let dh = 0;
  if (Cp1 * Cp2 !== 0) {
    dh = h2 - h1;
    if (dh > 180) dh -= 360; else if (dh < -180) dh += 360;
  }
  const dH = 2 * Math.sqrt(Cp1 * Cp2) * Math.sin((dh / 2) * rad);
  const Lb = (L1 + L2) / 2, Cbp = (Cp1 + Cp2) / 2;
  let hb;
  if (Cp1 * Cp2 === 0) hb = h1 + h2;
  else if (Math.abs(h1 - h2) <= 180) hb = (h1 + h2) / 2;
  else hb = h1 + h2 < 360 ? (h1 + h2 + 360) / 2 : (h1 + h2 - 360) / 2;
  const T = 1 - 0.17 * Math.cos((hb - 30) * rad) + 0.24 * Math.cos(2 * hb * rad)
    + 0.32 * Math.cos((3 * hb + 6) * rad) - 0.20 * Math.cos((4 * hb - 63) * rad);
  const Sl = 1 + (0.015 * (Lb - 50) ** 2) / Math.sqrt(20 + (Lb - 50) ** 2);
  const Sc = 1 + 0.045 * Cbp, Sh = 1 + 0.015 * Cbp * T;
  const Rt = -2 * Math.sqrt(Cbp ** 7 / (Cbp ** 7 + 25 ** 7))
    * Math.sin(60 * Math.exp(-(((hb - 275) / 25) ** 2)) * rad);
  return Math.sqrt((dL / Sl) ** 2 + (dC / Sc) ** 2 + (dH / Sh) ** 2
    + Rt * (dC / Sc) * (dH / Sh));
};

// A cartridge header just real enough for detectMonoPanel: only byte 0x143
// (the CGB flag) is read, but the length check needs a full header.
const cart = (cgbFlag) => {
  const b = new Uint8Array(0x200);
  b[0x143] = cgbFlag;
  return b;
};

const loadWithGame = async (opts = {}) => {
  const h = await loadApp(opts);
  h.sandbox.FS.files.set("rom.gb", cart(0x00));
  h.api.detectMonoPanel("rom.gb");
  return h;
};

// ── Mode selection ──────────────────────────────────────────────────────────

test("the default mode leaves the core's own shades alone", async () => {
  const h = await loadApp();
  assert.equal(h.api.gbPaletteMode, "default");
  assert.equal(h.api.gbPaletteColors(), null,
    "default mode must yield no palette at all — not a copy of the hardware " +
    "shades, which would bypass the LCD colour model and change the picture");
});

test("only one source is ever in force", async () => {
  const h = await loadApp();
  const custom = ["#ffffff", "#aaaaaa", "#555555", "#000000"];
  h.api.gbPaletteCustom = custom;

  h.api.gbPaletteMode = "custom";
  eq(h.api.gbPaletteColors(), custom);

  // Switching to "theme" does not blend with, or lose, the custom colours —
  // they are simply not the source any more.
  h.api.gbPaletteMode = "theme";
  eq(h.api.gbPaletteColors(), h.api.GB_THEME_PALETTES.amber);
  eq(h.api.gbPaletteCustom, custom);

  h.api.gbPaletteMode = "default";
  assert.equal(h.api.gbPaletteColors(), null);
});

test("theme mode tracks the app theme, live", async () => {
  const h = await loadApp();
  h.api.gbPaletteMode = "theme";
  eq(h.api.gbPaletteColors(), h.api.GB_THEME_PALETTES.amber);

  h.api.applyTheme("dmg");
  eq(h.api.gbPaletteColors(), h.api.GB_THEME_PALETTES.dmg,
    "a theme switch has to re-derive the palette — it is derived, not stored");

  h.api.applyTheme("famicom");
  eq(h.api.gbPaletteColors(), h.api.GB_THEME_PALETTES.famicom);
});

test("theme mode survives a theme this build no longer has", async () => {
  // "emerald" was renamed to "kiwi"; a stale stored value has to resolve
  // through the same migration the picker uses, not fall through to undefined.
  const h = await loadApp({ localStorageSeed: { dingbat_theme: "emerald" } });
  h.api.gbPaletteMode = "theme";
  eq(h.api.gbPaletteColors(), h.api.GB_THEME_PALETTES.kiwi);

  h.api.applyTheme("not-a-theme");
  eq(h.api.gbPaletteColors(), h.api.GB_THEME_PALETTES.amber);
});

test("the mode select drives the setting", async () => {
  const h = await loadApp();
  const sel = h.elements.get("gb-palette-mode");
  sel.value = "theme";
  await sel.dispatch("change");
  assert.equal(h.api.gbPaletteMode, "theme");

  // Anything unexpected in the control falls back to the safe mode.
  sel.value = "nonsense";
  await sel.dispatch("change");
  assert.equal(h.api.gbPaletteMode, "default");
});

test("the colour pickers are shown only in Custom mode", async () => {
  const h = await loadApp();
  const row = h.elements.get("gb-palette-custom-row");
  const sel = h.elements.get("gb-palette-mode");
  assert.equal(row.hidden, true, "default");
  sel.value = "theme"; await sel.dispatch("change");
  assert.equal(row.hidden, true, "theme");
  sel.value = "custom"; await sel.dispatch("change");
  assert.equal(row.hidden, false, "custom");
});

test("picking a shade edits that shade and only that shade", async () => {
  const h = await loadApp();
  h.api.gbPaletteMode = "custom";
  const input = h.elements.get("gb-palette-shade-2");
  input.value = "#123456";
  await input.dispatch("input");
  eq(h.api.gbPaletteColors(),
     [h.api.GB_HW_SHADES[0], h.api.GB_HW_SHADES[1], "#123456", h.api.GB_HW_SHADES[3]]);
});

// ── Persistence ─────────────────────────────────────────────────────────────

test("mode and custom colours survive a reload", async () => {
  const h = await loadApp();
  const sel = h.elements.get("gb-palette-mode");
  sel.value = "custom";
  await sel.dispatch("change");
  const input = h.elements.get("gb-palette-shade-0");
  input.value = "#ABCDEF";
  await input.dispatch("input");
  await settle();

  const stored = h.idb.get("gb-palette");
  assert.equal(stored.mode, "custom");
  assert.equal(stored.custom[0], "#abcdef");

  // Second boot: a fresh app reading the same store.
  const h2 = await loadApp();
  h2.idb.set("gb-palette", stored);
  await h2.api.loadGbPalette();
  assert.equal(h2.api.gbPaletteMode, "custom");
  assert.equal(h2.api.gbPaletteColors()[0], "#abcdef");
  assert.equal(h2.elements.get("gb-palette-mode").value, "custom",
    "the control has to come back showing what was restored");
});

test("a corrupt stored palette falls back instead of reaching the shader", async () => {
  const h = await loadApp();
  h.idb.set("gb-palette", { mode: "custom", custom: ["#fff", 7, null] });
  await h.api.loadGbPalette();
  assert.equal(h.api.gbPaletteMode, "custom");
  eq(h.api.gbPaletteColors(), h.api.GB_HW_SHADES,
    "a half-written record must not put non-colours in front of the renderer");
});

test("the palette record is a settings key", async () => {
  const h = await loadApp();
  assert.ok(h.api.SETTINGS_KEYS.includes("gb-palette"),
    "left out of SETTINGS_KEYS, the palette would survive Reset all settings " +
    "and be treated as game data by the delete paths");
});

// ── Reset ───────────────────────────────────────────────────────────────────

test("the palette's own Reset undoes the palette and nothing else", async () => {
  const h = await loadApp();
  // Set the palette AND an unrelated setting, then reset only the palette.
  const sel = h.elements.get("gb-palette-mode");
  sel.value = "custom";
  await sel.dispatch("change");
  const input = h.elements.get("gb-palette-shade-1");
  input.value = "#00ff00";
  await input.dispatch("input");

  const runahead = h.elements.get("runahead-select");
  runahead.value = "2";
  await runahead.dispatch("change");
  await settle();

  await h.elements.get("gb-palette-reset").dispatch("click");
  await settle();

  assert.equal(h.api.gbPaletteMode, "default");
  eq(h.api.gbPaletteCustom, h.api.GB_HW_SHADES);
  assert.equal(h.api.gbPaletteColors(), null);
  eq(h.idb.get("gb-palette"), { mode: "default", custom: h.api.GB_HW_SHADES });

  assert.equal(h.api.runaheadFrames, 2,
    "this Reset is scoped to the palette — the whole point of it existing " +
    "separately from Reset all settings");
  assert.equal(h.idb.get("runahead"), 2);
});

test("Reset all settings also clears the palette", async () => {
  const h = await loadApp();
  h.api.gbPaletteMode = "theme";
  h.idb.set("gb-palette", { mode: "theme", custom: h.api.GB_HW_SHADES });
  await h.api.resetAllSettings();
  await settle();
  assert.equal(h.api.gbPaletteMode, "default");
  assert.equal(h.idb.has("gb-palette"), false);
});

// ── Monochrome gate ─────────────────────────────────────────────────────────

test("only a monochrome cartridge gets a shade palette", async () => {
  const h = await loadApp();
  const set = (name, bytes) => h.sandbox.FS.files.set(name, bytes);

  set("rom.gb", cart(0x00));
  h.api.detectMonoPanel("rom.gb");
  assert.equal(h.api.gbMonoPanel, true, "a plain DMG cartridge");

  set("rom.gbc", cart(0x80));
  h.api.detectMonoPanel("rom.gbc");
  assert.equal(h.api.gbMonoPanel, false, "CGB-enhanced draws its own colours");

  set("rom.gbc", cart(0xC0));
  h.api.detectMonoPanel("rom.gbc");
  assert.equal(h.api.gbMonoPanel, false, "CGB-only draws its own colours");

  set("rom.gba", cart(0x00));
  h.api.detectMonoPanel("rom.gba");
  assert.equal(h.api.gbMonoPanel, false, "GBA has no DMG shades at all");
});

test("a CGB boot ROM colourises mono carts, so the palette stands down", async () => {
  const h = await loadApp();
  h.sandbox.FS.files.set("rom.gb", cart(0x00));
  // The core's own rule: bigger than the 256-byte DMG boot ROM => it is a CGB
  // boot ROM, which runs its own colourisation over a monochrome game.
  h.sandbox.FS.files.set("bootrom.bin", new Uint8Array(0x900));
  h.api.detectMonoPanel("rom.gb");
  assert.equal(h.api.gbMonoPanel, false);

  h.sandbox.FS.files.set("bootrom.bin", new Uint8Array(0x100));
  h.api.detectMonoPanel("rom.gb");
  assert.equal(h.api.gbMonoPanel, true, "a DMG-sized boot ROM changes nothing");
});

test("a truncated or missing ROM is not treated as monochrome", async () => {
  const h = await loadWithGame();
  assert.equal(h.api.gbMonoPanel, true);
  h.sandbox.FS.files.set("rom.gb", new Uint8Array(8));
  h.api.detectMonoPanel("rom.gb");
  assert.equal(h.api.gbMonoPanel, false);
  h.api.detectMonoPanel("nothing-here.gb");
  assert.equal(h.api.gbMonoPanel, false);
});

// ── The shipped theme palettes ──────────────────────────────────────────────

test("every app theme has a palette", async () => {
  const h = await loadApp();
  for (const name of h.api.THEME_NAMES) {
    assert.ok(h.api.GB_THEME_PALETTES[name],
      `theme "${name}" has no Game Boy palette — "Match app theme" would ` +
      `silently fall back to Amber on it`);
  }
});

test("every theme palette is a usable four-shade ramp", async () => {
  const h = await loadApp();
  for (const [name, pal] of Object.entries(h.api.GB_THEME_PALETTES)) {
    assert.equal(pal.length, 4, name);
    for (const c of pal) assert.match(c, /^#[0-9a-f]{6}$/, name + ": " + c);

    // Monotonically darkening: shade 0 is the "off" pixel and shade 3 the ink.
    // A ramp that wanders inverts sprites against their own backgrounds.
    const L = pal.map(relLum);
    for (let i = 1; i < 4; i++) {
      assert.ok(L[i] < L[i - 1],
        `${name}: shade ${i} is not darker than shade ${i - 1}`);
    }

    // The failure mode that makes a game unreadable is two adjacent shades
    // collapsing into each other. 1.4:1 is a floor drawn just under the real
    // hardware ramp's tightest step (1.64:1) — anything below it is a bug.
    for (let i = 1; i < 4; i++) {
      const c = contrast(pal[i - 1], pal[i]);
      assert.ok(c >= 1.4,
        `${name}: shades ${i - 1}/${i} collapse (${c.toFixed(2)}:1)`);
    }
    // …and the two ends must be far enough apart to read as black on white.
    const ends = contrast(pal[0], pal[3]);
    assert.ok(ends >= 7, `${name}: ends only ${ends.toFixed(2)}:1 apart`);
  }
});

test("no two adjacent shades are too far apart to dither together", async () => {
  // The other half of "a usable ramp", and the half the contrast floor above
  // cannot see. Games render half-tones by alternating two adjacent shades
  // pixel by pixel: a busy frame is mostly shades 1 and 2 mixed at 50%. That
  // only works if the pair reads as one intermediate tone. Two shades that
  // step down in luminance correctly but sit in different HUES do not blend —
  // they shimmer, and the screen reads as a fault rather than as a palette.
  //
  // The ceiling is drawn just above the widest step any shipped ramp takes
  // (`light`, 40.1 dE from its burnt amber to its navy ink, which is fine
  // because it is the 2->3 step and `light` is not a dithering-heavy look).
  // The ramp this caught was dmg's original pea-green -> magenta at 74 dE,
  // nearly double the worst of the other ten and unmistakable on screen.
  const MAX_ADJACENT_DE = 45;
  const h = await loadApp();
  for (const [name, pal] of Object.entries(h.api.GB_THEME_PALETTES)) {
    for (let i = 1; i < 4; i++) {
      const d = deltaE2000(pal[i - 1], pal[i]);
      assert.ok(d <= MAX_ADJACENT_DE,
        `${name}: shades ${i - 1}/${i} are ${d.toFixed(1)} dE2000 apart — too ` +
        `far to dither against each other (ceiling ${MAX_ADJACENT_DE})`);
    }
  }
});

test("each theme palette actually contains one of its theme's colours", async () => {
  // The rule these were built to: the theme's main colour appears verbatim,
  // not as a tint. Spot-checked against web/styles.css tokens so a future
  // theme tweak that orphans its palette shows up here.
  //
  // dmg is pinned to its magenta A/B buttons (--btn-ab-top) rather than to its
  // --accent, because it is the one theme whose accent is deliberately absent:
  // the pea-green LCD colour cannot sit next to the magenta without the pair
  // vibrating when a game dithers them (see the adjacent-dE test). Its ramp is
  // still four of the console's own colours, just not that one.
  const h = await loadApp();
  const mainColorOf = {
    amber: "#ffb04d", black: "#ffb04d", light: "#9c5400",
    indigo: "#7f6ae7", fuchsia: "#e8739a", glacier: "#769be5",
    kiwi: "#6ee126", dmg: "#b32e68", "atomic-purple": "#c36ee7",
    daiei: "#eb7c33", famicom: "#b99c68",
  };
  for (const [name, main] of Object.entries(mainColorOf)) {
    assert.ok(h.api.GB_THEME_PALETTES[name].includes(main),
      `${name}: the theme's main colour ${main} is not one of the four shades`);
  }
});
