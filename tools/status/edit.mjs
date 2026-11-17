#!/usr/bin/env node
// tools/status/edit: post an announcement or a required update in one go.
//
//   1. serves the editor (editor.html) on localhost and opens it;
//   2. its Save writes this checkout's web/status.json (checked first, rules.mjs);
//   3. Done (in the editor, or Enter here) checks the file again, shows the
//      diff and asks before committing web/status.json alone and pushing;
//   4. waits for dingbat.gg/status.json to match, so you know it is live.
//
// Options: --port N (default: any free port), --no-open, --no-push (commit only).

import { createServer } from "node:http";
import { readFile, writeFile } from "node:fs/promises";
import { execFileSync, spawn } from "node:child_process";
import { createInterface } from "node:readline";
import { extname, join, normalize, relative, resolve, sep } from "node:path";
import { fileURLToPath } from "node:url";
import { validate } from "./rules.mjs";

const ROOT = resolve(fileURLToPath(new URL("../..", import.meta.url)));
const FILE = join(ROOT, "web", "status.json");
const LIVE = "https://dingbat.gg/status.json";
const args = process.argv.slice(2);
const flag = (f) => args.includes(f);
const port = Number(args[args.indexOf("--port") + 1]) || 0;

const git = (...a) => execFileSync("git", ["-C", ROOT, ...a], { encoding: "utf8" }).trim();
const TYPES = { ".html": "text/html", ".mjs": "text/javascript", ".js": "text/javascript", ".json": "application/json",
  ".css": "text/css", ".svg": "image/svg+xml", ".png": "image/png" };

let done;
const finished = new Promise((r) => (done = r));

const reply = (res, code, body, type = "application/json") => {
  res.writeHead(code, { "Content-Type": type, "Cache-Control": "no-store" });
  res.end(typeof body === "string" ? body : JSON.stringify(body));
};
const readBody = (req) => new Promise((ok, fail) => {
  let s = "";
  req.on("data", (c) => { s += c; if (s.length > 1 << 20) req.destroy(); });
  req.on("end", () => ok(s));
  req.on("error", fail);
});

const server = createServer(async (req, res) => {
  const url = new URL(req.url, "http://localhost");
  try {
    // The editor's tool mode: it saves here instead of a file picker.
    if (url.pathname === "/__status/file" && req.method === "GET") {
      return reply(res, 200, await readFile(FILE, "utf8"), "application/json");
    }
    if (url.pathname === "/__status/save" && req.method === "POST") {
      const text = await readBody(req);
      let doc;
      try { doc = JSON.parse(text); } catch (e) { return reply(res, 400, { errors: [{ path: "", msg: e.message }] }); }
      const { errors } = validate(doc);
      if (errors.length) return reply(res, 422, { errors });
      await writeFile(FILE, text.endsWith("\n") ? text : text + "\n");
      console.log(`saved web/status.json (${new Date().toLocaleTimeString()})`);
      return reply(res, 200, { ok: true });
    }
    if (url.pathname === "/__status/commit" && req.method === "GET") {
      // A commit's build time, as deploy-pages.yml and the iOS build stamp it.
      const sha = url.searchParams.get("sha") || "";
      if (!/^([0-9a-fA-F]{4,40}|HEAD(~\d{1,4})?)$/.test(sha)) return reply(res, 400, { error: "a sha, HEAD or HEAD~N" });
      try {
        const time = execFileSync("git", ["-C", ROOT, "show", "-s", "--date=format-local:%Y-%m-%dT%H:%M:%SZ", "--format=%cd %h %s", sha],
          { encoding: "utf8", env: { ...process.env, TZ: "UTC" } }).trim();
        const [t, h, ...subject] = time.split(" ");
        return reply(res, 200, { time: t, sha: h, subject: subject.join(" ") });
      } catch { return reply(res, 404, { error: `no commit ${sha} here` }); }
    }
    if (url.pathname === "/__status/done" && req.method === "POST") {
      reply(res, 200, { ok: true });
      return done();
    }
    if (req.method !== "GET") return reply(res, 405, "", "text/plain");
    // Files: the repo root, nothing above it.
    const path = normalize(join(ROOT, decodeURIComponent(url.pathname)));
    if (relative(ROOT, path).startsWith("..") || (path !== ROOT && !path.startsWith(ROOT + sep))) return reply(res, 403, "", "text/plain");
    const body = await readFile(path);
    res.writeHead(200, { "Content-Type": TYPES[extname(path)] || "application/octet-stream", "Cache-Control": "no-store" });
    res.end(body);
  } catch {
    reply(res, 404, "", "text/plain");
  }
});

server.listen(port, "127.0.0.1", () => {
  const where = `http://localhost:${server.address().port}/tools/status/editor.html`;
  console.log(`editor: ${where}`);
  console.log("Save in the editor writes web/status.json. Click Done there, or press Enter here, when you're finished.");
  if (!flag("--no-open")) {
    const opener = process.platform === "darwin" ? "open" : process.platform === "win32" ? "explorer" : "xdg-open";
    spawn(opener, [where], { stdio: "ignore", detached: true }).on("error", () => {}).unref();
  }
});

const rl = createInterface({ input: process.stdin, output: process.stdout });
const ask = (q) => new Promise((r) => rl.question(q, r));
rl.once("line", () => done());
rl.on("SIGINT", () => { console.log("\nstopped; nothing committed"); process.exit(130); });

await finished;
server.close();
rl.removeAllListeners("line");

// --- check, show, commit, push ---
const text = await readFile(FILE, "utf8");
const { errors, warnings } = validate(JSON.parse(text));
for (const w of warnings) console.log(`warning: ${w.path}: ${w.msg}`);
if (errors.length) {
  for (const e of errors) console.log(`error: ${e.path}: ${e.msg}`);
  console.log("web/status.json has errors: nothing committed.");
  process.exit(1);
}
const diff = git("diff", "--", "web/status.json");
if (!diff) { console.log("web/status.json is unchanged: nothing to commit."); process.exit(0); }
console.log("\n" + diff + "\n");

let before = {};
try { before = JSON.parse(git("show", "HEAD:web/status.json")); } catch {}
const after = JSON.parse(text);
const ids = (d) => new Set((d.announcements || []).map((a) => a.id));
const added = [...ids(after)].filter((i) => !ids(before).has(i));
const removed = [...ids(before)].filter((i) => !ids(after).has(i));
const parts = [
  added.length && `post ${added.join(", ")}`,
  removed.length && `remove ${removed.join(", ")}`,
  (after.required || []).length !== (before.required || []).length && `required updates: ${(after.required || []).length}`,
].filter(Boolean);
const suggested = `status: ${parts.join("; ") || "edit announcements"}`;
const branch = git("rev-parse", "--abbrev-ref", "HEAD");
const push = !flag("--no-push");
const message = (await ask(`Commit message [${suggested}]: `)).trim() || suggested;
const yes = (await ask(`Commit web/status.json${push ? ` and push ${branch}` : ""}? [y/N] `)).trim().toLowerCase() === "y";
rl.close();
if (!yes) { console.log("Not committed; web/status.json is saved."); process.exit(0); }

execFileSync("git", ["-C", ROOT, "commit", "-m", message, "--", "web/status.json"], { stdio: "inherit" });
if (!push) process.exit(0);
try {
  execFileSync("git", ["-C", ROOT, "pull", "--rebase", "--autostash"], { stdio: "inherit" });
  execFileSync("git", ["-C", ROOT, "push"], { stdio: "inherit" });
} catch {
  console.log("The push failed: the commit is here; push it by hand.");
  process.exit(1);
}
if (branch !== "main") {
  console.log(`Pushed ${branch}. dingbat.gg serves main: it goes live once this lands there.`);
  process.exit(0);
}

// --- wait for dingbat.gg ---
console.log(`Waiting for ${LIVE} (the deploy takes about a minute, the CDN up to ten more)…`);
const want = JSON.stringify(after);
const start = Date.now();
while (Date.now() - start < 15 * 60 * 1000) {
  try {
    const res = await fetch(`${LIVE}?probe=${Date.now()}`, { cache: "no-store" });
    if (res.ok && JSON.stringify(await res.json()) === want) {
      console.log(`Live on dingbat.gg after ${Math.round((Date.now() - start) / 1000)} s.`);
      process.exit(0);
    }
  } catch {}
  await new Promise((r) => setTimeout(r, 15000));
}
console.log("Not live after 15 minutes: check the deploy (gh run list --workflow deploy-pages.yml).");
process.exit(1);
