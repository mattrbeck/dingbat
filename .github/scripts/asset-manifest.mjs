// web/asset-manifest.json: the digest of every file web/sw.js precaches, for
// its install to check each copy it keeps against (sw.js, collect), and of
// each file of the DS core it keeps once fetched (sw.js LAZY, under `lazy`:
// workers from before it check that `files` lists exactly their ASSETS). Run by
// deploy-pages.yml after the last step that rewrites a precached file (the
// service worker's version stamp), so the digests are of the bytes Pages
// serves.
//
//   node .github/scripts/asset-manifest.mjs <site dir>
//
// The lists are sw.js's own ASSETS and LAZY and the version its
// CACHE_VERSION, so the two cannot disagree; "./" is the site's index.html,
// as Pages serves it. A file missing from the site fails it (and the deploy).
// Nothing in it depends on the time or the machine: the build stays
// reproducible.

import { createHash } from "node:crypto";
import { readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const swList = (swSource, name) => {
  const m = swSource.match(new RegExp(`const ${name} = \\[([^\\]]+)\\]`));
  if (!m) throw new Error(name + " list not found in sw.js");
  return [...m[1].matchAll(/"(\.\/[^"]*)"/g)].map((x) => x[1]);
};
export const swAssets = (swSource) => swList(swSource, "ASSETS");
export const swLazy = (swSource) => swList(swSource, "LAZY");

export const swVersion = (swSource) => {
  const m = swSource.match(/const CACHE_VERSION = "([^"]+)"/);
  if (!m) throw new Error("CACHE_VERSION not found in sw.js");
  return m[1];
};

export const fileFor = (url) => (url === "./" ? "index.html" : url.slice(2));

export const sha256 = (bytes) => createHash("sha256").update(bytes).digest("hex");

export const buildManifest = (dir) => {
  const sw = readFileSync(join(dir, "sw.js"), "utf8");
  const digests = (urls) =>
    Object.fromEntries(urls.map((u) => [u, sha256(readFileSync(join(dir, fileFor(u))))]));
  // Each file's size in bytes (decoded, as the worker reads it): what an
  // install or a Force update has to come is the sum of these, for the
  // progress it shows the page. Workers from before it ignore the key.
  const sizes = (urls) =>
    Object.fromEntries(urls.map((u) => [u, statSync(join(dir, fileFor(u))).size]));
  return { version: swVersion(sw), files: digests(swAssets(sw)), lazy: digests(swLazy(sw)),
           sizes: sizes([...swAssets(sw), ...swLazy(sw)]) };
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
  console.log(`asset-manifest.json: ${Object.keys(m.files).length} files, ` +
              `${Object.keys(m.lazy).length} lazy, version ${m.version}`);
}
