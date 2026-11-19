// The Content-Security-Policy of web/index.html: a <meta> tag (GitHub Pages
// sends no headers of ours), whose script-src names each inline script by
// its SHA-256. `node tools/csp.mjs` rewrites the tag; `--check [file]` fails
// when a file's tag is not the one its scripts need.
import { createHash } from "node:crypto";
import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const INDEX = join(dirname(fileURLToPath(import.meta.url)), "..", "web", "index.html");
const META = /<meta http-equiv="Content-Security-Policy"\s+content="[^"]*"\s*\/>/;

export const inlineScriptHashes = (html) =>
  [...html.matchAll(/<script>([\s\S]*?)<\/script>/g)].map((m) =>
    "'sha256-" + createHash("sha256").update(m[1], "utf8").digest("base64") + "'");

export const policy = (html) => [
  "default-src 'self'",
  // wasm-unsafe-eval: compiling em.wasm. blob: the audio worklets, whose
  // source is built in the page. Google's sign-in library is the one script
  // from elsewhere.
  ["script-src 'self' 'wasm-unsafe-eval' blob: https://accounts.google.com/gsi/client",
    ...inlineScriptHashes(html)].join(" "),
  "style-src 'self' https://accounts.google.com/gsi/style",
  "img-src 'self' blob: data:",
  "media-src 'self' blob: data:",
  // https: is the save webhook, which posts to any address the player sets;
  // without it this is Google's two API hosts and the signaling server. The
  // local addresses are a signaling server run beside a local build.
  "connect-src 'self' blob: data: https: wss: ws://localhost:* ws://127.0.0.1:* http://localhost:* http://127.0.0.1:*",
  "frame-src https://accounts.google.com/gsi/",
  "worker-src 'self'",
  "manifest-src 'self'",
  "object-src 'none'",
  "base-uri 'none'",
  "form-action 'none'",
].join("; ");

export const metaTag = (html) =>
  `<meta http-equiv="Content-Security-Policy"\n      content="${policy(html)}" />`;

// What is wrong with a page's tag, or null.
export const problem = (html) => {
  const found = html.match(META);
  if (!found) return "no Content-Security-Policy meta tag";
  if (html.indexOf("<script") < found.index) return "a script comes before the policy";
  if (found[0] !== metaTag(html)) return "the policy is not the one this page's inline scripts need: run node tools/csp.mjs";
  return null;
};

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  const check = process.argv[2] === "--check";
  const file = (check ? process.argv[3] : process.argv[2]) || INDEX;
  const html = readFileSync(file, "utf8");
  if (check) {
    const p = problem(html);
    if (p) { console.error(`${file}: ${p}`); process.exit(1); }
  } else {
    if (!META.test(html)) { console.error(`${file}: no Content-Security-Policy meta tag to rewrite`); process.exit(1); }
    writeFileSync(file, html.replace(META, () => metaTag(html)));
  }
}
