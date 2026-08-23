// The new-photo dots (hamburger, Capture row, Printed Photos row) and what
// the print toast's "View" does with them. The rule turns on a "has ever"
// flag (everOpenedFromMenu), so each case is pinned from both sides: what
// clears, and what deliberately does not.
import test from "node:test";
import assert from "node:assert/strict";
import { loadApp, settle } from "./helpers.mjs";

const photo = (n = 1) => ({ w: 160, h: 144, png: "data:image/png;base64,x" + n,
                            ts: 1700000000000 + n, game: "demo.gb" });

const dots = (app) => ({
  menu: app.document.getElementById("menu-btn").classList.contains("has-new-photo"),
  capture: app.document.getElementById("capture-toggle").classList.contains("has-new-photo"),
  gallery: app.document.getElementById("open-prints").classList.contains("has-new-photo"),
});
const ALL_LIT = { menu: true, capture: true, gallery: true };
const NONE_LIT = { menu: false, capture: false, gallery: false };

const viewPill = (app) => app.toastEl.children.find((c) =>
  c.classList.contains("has-action") && !c.classList.contains("leaving"));

const openMenu = async (app) => {
  app.document.getElementById("menu-dropdown").hidden = true;
  await app.document.getElementById("menu-btn").dispatch("click");
};
// Toggles, so start collapsed.
const expandCapture = async (app) => {
  app.document.getElementById("capture-sub").hidden = true;
  await app.document.getElementById("capture-toggle").dispatch("click");
};
const openGalleryFromMenu = (app) =>
  app.document.getElementById("open-prints").dispatch("click");

const printOne = async (app, n = 1) => {
  await app.api.storePrint(photo(n));
  await settle();
};

test("with no photos there is no row and no dot", async () => {
  const app = await loadApp();
  await app.api.loadPrinterPhotos();
  await settle();
  assert.equal(app.document.getElementById("open-prints").hidden, true,
    "an always-present row for an always-empty gallery is the menu weight " +
    "this move exists to remove");
  assert.deepEqual(dots(app), NONE_LIT);
});

test("the first print puts the row in the menu and lights all three dots", async () => {
  const app = await loadApp();
  await app.api.loadPrinterPhotos();
  await printOne(app);
  assert.equal(app.document.getElementById("open-prints").hidden, false);
  assert.deepEqual(dots(app), ALL_LIT);
  assert.ok(app.toasts.includes("Photo printed"));
});

test("each dot clears on its own element and leaves the others alone", async () => {
  const app = await loadApp();
  await app.api.loadPrinterPhotos();
  await printOne(app);

  await openMenu(app);
  assert.deepEqual(dots(app), { menu: false, capture: true, gallery: true },
    "opening the menu says nothing about whether Capture was found");

  await expandCapture(app);
  assert.deepEqual(dots(app), { menu: false, capture: false, gallery: true },
    "and expanding Capture says nothing about whether the gallery was opened");

  await openGalleryFromMenu(app);
  assert.deepEqual(dots(app), NONE_LIT, "the last dot is still lit on arrival");
});

test("CASE A — never opened from the menu: tapping View changes nothing", async () => {
  const app = await loadApp();
  await app.api.loadPrinterPhotos();
  await printOne(app);
  assert.equal(app.api.photoDots.everOpenedFromMenu, false);

  viewPill(app).onclick();
  await settle();

  assert.deepEqual(dots(app), ALL_LIT,
    "the trail is the only thing that will ever teach this person that the " +
    "gallery has a fixed address in the menu — a toast they will not see " +
    "again cannot");
  assert.equal(app.api.photoDots.everOpenedFromMenu, false,
    "and the toast route must not claim credit for teaching the address");
});

test("CASE B — opened from the menu before: tapping View clears all three", async () => {
  const app = await loadApp();
  await app.api.loadPrinterPhotos();
  await printOne(app, 1);
  await openGalleryFromMenu(app);
  app.api.closePrintsModal();
  await settle();
  assert.equal(app.api.photoDots.everOpenedFromMenu, true);

  await printOne(app, 2);
  assert.deepEqual(dots(app), ALL_LIT, "a new photo still lights the trail");

  viewPill(app).onclick();
  await settle();
  assert.deepEqual(dots(app), NONE_LIT,
    "they know where the gallery lives, so the dots have no lesson left");
});

test("both the dots and the has-ever flag survive a reload", async () => {
  const first = await loadApp();
  await first.api.loadPrinterPhotos();
  await printOne(first, 1);
  await openGalleryFromMenu(first);          // sets everOpenedFromMenu
  first.api.closePrintsModal();
  await settle();
  await printOne(first, 2);                  // relights the trail
  await openMenu(first);                     // clears one of the three
  await settle();
  assert.deepEqual(dots(first), { menu: false, capture: true, gallery: true });

  const second = await loadApp();
  second.idb.clear();
  for (const [k, v] of first.idb) second.idb.set(k, v);
  await second.api.loadPrinterPhotos();
  await settle();

  assert.equal(second.document.getElementById("open-prints").hidden, false);
  assert.deepEqual(dots(second), { menu: false, capture: true, gallery: true },
    "a half-walked trail must not restart at the top after a reload");
  assert.equal(second.api.photoDots.everOpenedFromMenu, true,
    "nor must Case B silently become Case A again");

  await printOne(second, 3);
  viewPill(second).onclick();
  await settle();
  assert.deepEqual(dots(second), NONE_LIT);
});

test("a dot never outlives the photos it points at", async () => {
  const first = await loadApp();
  await first.api.loadPrinterPhotos();
  await printOne(first, 1);

  // Photo record gone, dot record not (old install, or a gallery emptied by
  // another tab): the row hides, so the dot must too.
  const second = await loadApp();
  second.idb.clear();
  for (const [k, v] of first.idb) second.idb.set(k, v);
  second.idb.set(first.api.PRINTER_PHOTOS_KEY, []);
  await second.api.loadPrinterPhotos();
  await settle();

  assert.equal(second.document.getElementById("open-prints").hidden, true);
  assert.deepEqual(dots(second), NONE_LIT);
});

test("a print that lands in an already-open gallery raises nothing", async () => {
  const app = await loadApp();
  await app.api.loadPrinterPhotos();
  app.api.openPrintsModal();
  await printOne(app);

  assert.deepEqual(dots(app), NONE_LIT, "it is on screen; nothing is unseen");
  assert.equal(viewPill(app), undefined, "and there is nowhere to be taken");
});

test("photos survive a reload at all", async () => {
  // Pins loadPrinterPhotos on the boot path: without it the next print
  // writes a one-element array over every earlier photo.
  const first = await loadApp();
  await first.api.loadPrinterPhotos();
  await printOne(first, 1);
  await printOne(first, 2);

  const second = await loadApp();
  second.idb.clear();
  for (const [k, v] of first.idb) second.idb.set(k, v);
  await second.api.loadPrinterPhotos();
  await settle();
  assert.equal(second.api.printerPhotos.length, 2);

  await printOne(second, 3);
  assert.equal(second.api.printerPhotos.length, 3,
    "a print must extend the stored gallery, not replace it");
  assert.equal(second.idb.get(second.api.PRINTER_PHOTOS_KEY).length, 3);
});
