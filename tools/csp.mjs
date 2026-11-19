// The Content-Security-Policy of each web page that has one: a <meta> tag
// (GitHub Pages sends no headers of ours) naming the page's inline scripts
// and style blocks by SHA-256. `node tools/csp.mjs` rewrites every page's
// tag; `--check [file]` fails when a page's tag (or the named one's) is not
// the one its inline code needs.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { basename, dirname, join } from "node:path";

const WEB = join(dirname(fileURLToPath(import.meta.url)), "..", "web");
const META = /<meta http-equiv="Content-Security-Policy"\s+content="[^"]*"\s*\/>/;

const sha = (text) => "'sha256-" + createHash("sha256").update(text, "utf8").digest("base64") + "'";
export const inlineScriptHashes = (html) =>
  [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) => sha(m[1]));
const styleBlockHashes = (html) =>
  [...html.matchAll(/<style>([\s\S]*?)<\/style>/g)].map((m) => sha(m[1]));

const POLICIES = {
  "index.html": (html) => [
    "default-src 'self'",
    // wasm-unsafe-eval: compiling em.wasm. blob: the audio worklets, whose
    // source is built in the page. Google's sign-in library is the one
    // script from elsewhere.
    ["script-src 'self' 'wasm-unsafe-eval' blob: https://accounts.google.com/gsi/client",
      ...inlineScriptHashes(html)].join(" "),
    "style-src 'self' https://accounts.google.com/gsi/style",
    "img-src 'self' blob: data:",
    "media-src 'self' blob: data:",
    // https: is the save webhook, which posts to any address the player
    // sets; without it this is Google's two API hosts and the signaling
    // server. The local addresses are a signaling server run beside a
    // local build.
    "connect-src 'self' blob: data: https: wss: ws://localhost:* ws://127.0.0.1:* http://localhost:* http://127.0.0.1:*",
    "frame-src https://accounts.google.com/gsi/",
    "worker-src 'self'",
    "manifest-src 'self'",
    "object-src 'none'",
    "base-uri 'none'",
    "form-action 'none'",
  ].join("; "),
  // Google's redirect target: its one script and its one style block, and
  // nothing else at all.
  "oauth-callback.html": (html) => [
    "default-src 'none'",
    ["script-src", ...inlineScriptHashes(html)].join(" "),
    ["style-src", ...styleBlockHashes(html)].join(" "),
    "base-uri 'none'",
    "form-action 'none'",
  ].join("; "),
};
export const PAGES = Object.keys(POLICIES);

export const policy = (html, page = "index.html") => POLICIES[page](html);
export const metaTag = (html, page = "index.html") =>
  `<meta http-equiv="Content-Security-Policy"\n      content="${policy(html, page)}" />`;

// What is wrong with a page's tag, or null.
export const problem = (html, page = "index.html") => {
  const found = html.match(META);
  if (!found) return "no Content-Security-Policy meta tag";
  const first = Math.min(...["<script", "<style"].map((t) => html.indexOf(t)).filter((i) => i >= 0));
  if (first < found.index) return "a script or style comes before the policy";
  if (found[0] !== metaTag(html, page)) return "the policy is not the one this page's inline code needs: run node tools/csp.mjs";
  return null;
};

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const check = process.argv[2] === "--check";
  const named = check ? process.argv[3] : process.argv[2];
  const files = named ? [named] : PAGES.map((p) => join(WEB, p));
  let failed = false;
  for (const file of files) {
    const page = basename(file);
    if (!POLICIES[page]) { console.error(`${file}: no policy is defined for this page`); failed = true; continue; }
    const html = readFileSync(file, "utf8");
    if (check) {
      const p = problem(html, page);
      if (p) { console.error(`${file}: ${p}`); failed = true; }
    } else if (!META.test(html)) {
      console.error(`${file}: no Content-Security-Policy meta tag to rewrite`); failed = true;
    } else {
      writeFileSync(file, html.replace(META, () => metaTag(html, page)));
    }
  }
  if (failed) process.exit(1);
}
