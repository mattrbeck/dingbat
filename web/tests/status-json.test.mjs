// web/status.json passes tools/status/rules.mjs (the deploy runs the same
// check), and the rules catch what clients would silently misread.

import test from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { validate, announcementFor, requiredFor } from "../../tools/status/rules.mjs";
import { loadApp } from "./helpers.mjs";

const NOW = Date.parse("2026-11-16T12:00:00Z");
const paths = (r) => r.errors.map((e) => e.path);

test("web/status.json is valid", () => {
  const doc = JSON.parse(readFileSync(new URL("../status.json", import.meta.url), "utf8"));
  const { errors } = validate(doc);
  assert.deepEqual(errors, []);
});

test("a full, correct file has no errors", () => {
  const r = validate({
    announcements: [
      { id: "a1", text: "Hello", show: ["toast", "banner"], platforms: ["web", "ios"],
        url: "https://dingbat.gg/", label: "Read more",
        from: "2026-11-16T00:00:00Z", until: "2026-11-20T00:00:00Z", builtBefore: "2026-11-10T00:00:00Z" },
    ],
    required: [
      { platforms: ["web"], minBuild: "2026-11-10T00:00:00Z", message: "Fix" },
      { platforms: ["ios"], minBuild: "2026-11-10T00:00:00Z", url: "https://apps.apple.com/app/id1" },
    ],
  }, NOW);
  assert.deepEqual(r.errors, []);
  assert.deepEqual(r.warnings, []);
});

test("times iOS can't read are errors, though web would take them", () => {
  for (const t of ["2026-11-16T10:00:00.000Z", "2026-11-16", "2026-11-16T10:00:00", "2026-11-16T10:00:00+01:00"]) {
    const r = validate({ announcements: [{ id: "a", text: "x", until: t }] }, NOW);
    assert.deepEqual(paths(r), ["announcements[0].until"], t);
  }
});

test("typos, duplicates and unknown values are errors", () => {
  const r = validate({
    announcements: [
      { id: "a", text: "x", untill: "2026-11-20T00:00:00Z", show: ["popup"], platforms: ["android"] },
      { id: "a", text: "" },
      { id: "b", text: "x", url: "http://dingbat.gg/" },
    ],
    requird: [],
  }, NOW);
  assert.deepEqual(paths(r).sort(), [
    "announcements[0].platforms", "announcements[0].show", "announcements[0].untill",
    "announcements[1].id", "announcements[1].text", "announcements[2].url", "requird",
  ]);
});

test("an iOS requirement needs its link; a future iOS minBuild warns", () => {
  const r = validate({ required: [{ minBuild: "2026-12-01T00:00:00Z" }] }, NOW);
  assert.deepEqual(paths(r), ["required[0].url"]);
  assert.deepEqual(r.warnings.map((w) => w.path), ["required[0].minBuild"]);
  assert.deepEqual(validate({ required: [{ platforms: ["web"], minBuild: "2026-12-01T00:00:00Z" }] }, NOW).errors, []);
});

test("a window that never opens is an error; one that has closed warns", () => {
  const never = validate({ announcements: [{ id: "a", text: "x", from: "2026-11-20T00:00:00Z", until: "2026-11-19T00:00:00Z" }] }, NOW);
  assert.deepEqual(paths(never), ["announcements[0].until"]);
  const over = validate({ announcements: [{ id: "a", text: "x", until: "2026-11-01T00:00:00Z" }] }, NOW);
  assert.deepEqual(over.errors, []);
  assert.equal(over.warnings[0].path, "announcements[0].until");
});

test("builtAfter: a time, and before builtBefore; a left-over [placeholder] is an error", () => {
  const r = validate({ announcements: [
    { id: "a", text: "x", builtAfter: "2026-11-10T00:00:00Z", builtBefore: "2026-11-01T00:00:00Z" },
    { id: "b", text: "x", builtAfter: "soon" },
    { id: "c", text: "New: [feature] is here." },
    { id: "d", text: "x", builtAfter: "2026-11-01T00:00:00Z", builtBefore: "2026-11-10T00:00:00Z" },
  ] }, NOW);
  assert.deepEqual(paths(r), ["announcements[0].builtAfter", "announcements[1].builtAfter", "announcements[2].text"]);
});

test("the editor's who-sees-this matches the web app, entry by entry and build by build", async () => {
  const T = (d) => `2026-11-${d}T00:00:00Z`;
  const entries = [];
  let n = 0;
  for (const platforms of [undefined, ["web"], ["ios"]])
    for (const win of [{}, { from: T(10) }, { from: T(20) }, { until: T(12) }, { from: T(1), until: T(30) }])
      for (const built of [{}, { builtBefore: T(10) }, { builtAfter: T(10) }, { builtAfter: T(5), builtBefore: T(15) }])
        entries.push({ id: "e" + n++, text: "x", ...(platforms && { platforms }), ...win, ...built });
  const now = Date.parse(T(16));
  for (const build of ["", T("01"), T("10"), T(14)]) {
    const app = await loadApp();
    app.runIn(`BUILD_TIME = ${JSON.stringify(build)}`);
    const web = app.runIn(`(${JSON.stringify(entries)}).map((a) => announcementApplies(a, ${now}))`);
    const rules = entries.map((a) => announcementFor(a, { platform: "web", built: build ? Date.parse(build) : null, now }).shows);
    assert.deepEqual([...web], rules, `build ${build || "dev"}`);
  }
});

test("requiredFor: platform, then build time; a development build is never blocked", () => {
  const r = { platforms: ["ios"], minBuild: "2026-11-10T00:00:00Z", url: "https://apps.apple.com/app/id1" };
  assert.equal(requiredFor(r, { platform: "web", built: 0 }).blocks, false);
  assert.equal(requiredFor(r, { platform: "ios", built: Date.parse("2026-11-01T00:00:00Z") }).blocks, true);
  assert.equal(requiredFor(r, { platform: "ios", built: Date.parse("2026-11-10T00:00:00Z") }).blocks, false);
  assert.equal(requiredFor(r, { platform: "ios", built: null }).blocks, false);
});
