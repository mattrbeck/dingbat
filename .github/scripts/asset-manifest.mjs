// web/asset-manifest.json: the digest of every file web/sw.js precaches, for
// its install to check each copy it keeps against (sw.js, collect). Run by
// deploy-pages.yml after the last step that rewrites a precached file (the
// service worker's version stamp), so the digests are of the bytes Pages
// serves.
//
//   node .github/scripts/asset-manifest.mjs <site dir>
//
// The list is sw.js's own ASSETS and the version its CACHE_VERSION, so the
// two cannot disagree; "./" is the site's index.html, as Pages serves it.
// Nothing in it depends on the time or the machine: the build stays
// reproducible.

import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

export const swAssets = (swSource) => {
  const m = swSource.match(/const ASSETS = \[([^\]]+)\]/);
  if (!m) throw new Error("ASSETS list not found in sw.js");
  return [...m[1].matchAll(/"(\.\/[^"]*)"/g)].map((x) => x[1]);
};

export const swVersion = (swSource) => {
  const m = swSource.match(/const CACHE_VERSION = "([^"]+)"/);
  if (!m) throw new Error("CACHE_VERSION not found in sw.js");
  return m[1];
};

export const fileFor = (url) => (url === "./" ? "index.html" : url.slice(2));

export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

export const buildManifest = (dir) => {
  const sw = readFileSync(join(dir, "sw.js"), "utf8");
  const files = {};
  for (const u of swAssets(sw)) files[u] = sha256(readFileSync(join(dir, fileFor(u))));
  return { version: swVersion(sw), files };
};

export const writeManifest = (dir) => {
  const m = buildManifest(dir);
  writeFileSync(join(dir, "asset-manifest.json"), JSON.stringify(m, null, 1) + "\n");
  return m;
};

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  const dir = process.argv[2];
  if (!dir) {
    console.error("usage: node .github/scripts/asset-manifest.mjs <site dir>");
    process.exit(2);
  }
  // A dev worker never reads one: a manifest saying "dev" means the stamp
  // did not run.
  if (buildManifest(dir).version === "dev") {
    console.error("sw.js still says CACHE_VERSION = \"dev\": stamp it first");
    process.exit(1);
  }
  const m = writeManifest(dir);
  console.log(`asset-manifest.json: ${Object.keys(m.files).length} files, version ${m.version}`);
}
