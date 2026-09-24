// Which Lean models no longer describe the code they model.
//
// The proofs in formal/ are about models, and nothing in `lake build` reads
// the JS or the Nim: a change to loadRom leaves WebState/GameLifecycle.lean
// proving things about code that no longer exists. The models are an audit's snapshot, not a
// contract every commit keeps (the regression tests in web/tests/ are that),
// so this is not a CI gate: run it when starting the next audit, and it says
// which machines changed since the last one and need modelling again. Each
// model names what it models, one line per file:
//
//   -- @models web/index.js: loadRom launchRom on:visibilitychange
//   -- @models src/dingbat.nim: load_rom handle_input main
//
// In a .js file a name is a top-level `const`/`let`/`function` declaration,
// or `on:<event>` for every top-level `x.addEventListener("<event>", ...)`
// together. In a .nim file it is a top-level `proc`/`func`/`iterator`/
// `template`/`macro`/`method`/`converter` (a forward declaration and the body
// together), `var`/`let`/`const`, or one-line `type`, each running to the
// next line that starts in column 0. This script hashes each one's tokens
// (comments and whitespace do not count, so rewording a comment never trips
// it) and compares with anchors.json, keyed by the model's path under formal/
// (`WebState/RunPause`, `DesktopState/NetLink`).
//
//   node formal/anchors.mjs                  list the stale models (exit 1 if any)
//   node formal/anchors.mjs --update         stamp every model, once they match the code again
//   node formal/anchors.mjs --update M ...   stamp only these (`DesktopState/NetLink`, or a
//                                            whole directory: `DesktopState`)
//
// Needs web/node_modules (typescript, already a devDependency for tsc).

import fs from "node:fs";
import path from "node:path";
import crypto from "node:crypto";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const here = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(here, "..");
const ts = createRequire(path.join(root, "web/package.json"))("typescript");
const anchorsFile = path.join(here, "anchors.json");

// Token stream of a node, trivia skipped: the hash moves only with code.
const tokenHash = (text) => {
  const sc = ts.createScanner(ts.ScriptTarget.Latest, /*skipTrivia*/ true,
                              ts.LanguageVariant.Standard, text);
  const h = crypto.createHash("sha256");
  for (let k = sc.scan(); k !== ts.SyntaxKind.EndOfFileToken; k = sc.scan()) {
    h.update(sc.getTokenText());
    h.update("\u0000");
  }
  return h.digest("hex").slice(0, 16);
};

// Nim has no scanner in node_modules. This one drops comments (`# ...` and
// nestable `#[ ... ]#`) and whitespace, and keeps string and char literals
// whole so a `#` inside one is not a comment.
const nimTokens = (text) => {
  const out = [];
  const n = text.length;
  let i = 0;
  while (i < n) {
    const c = text[i];
    if (c === "#") {
      if (text[i + 1] === "[" || (text[i + 1] === "#" && text[i + 2] === "[")) {
        let depth = 0;
        while (i < n) {
          if (text[i] === "#" && text[i + 1] === "[") { depth++; i += 2; }
          else if (text[i] === "]" && text[i + 1] === "#") { depth--; i += 2; if (depth === 0) break; }
          else i++;
        }
      } else {
        while (i < n && text[i] !== "\n") i++;
      }
    } else if (/\s/.test(c)) {
      i++;
    } else if (text.startsWith('"""', i)) {
      const j = text.indexOf('"""', i + 3);
      const e = j < 0 ? n : j + 3;
      out.push(text.slice(i, e));
      i = e;
    } else if (c === '"') {
      const raw = i > 0 && /[A-Za-z]/.test(text[i - 1]);  // r"..." / fmt"...": no escapes
      let j = i + 1;
      while (j < n && text[j] !== '"' && text[j] !== "\n") j += !raw && text[j] === "\\" ? 2 : 1;
      out.push(text.slice(i, j + 1));
      i = j + 1;
    } else {
      const m = /^(?:'(?:\\[^']*|[^'\\])'|[A-Za-z_][A-Za-z0-9_]*|[0-9][A-Za-z0-9_.']*|[=+\-*/<>@$~&%|!?^.:\\]+|.)/.exec(text.slice(i, i + 64));
      out.push(m[0]);
      i += m[0].length;
    }
  }
  return out;
};

const nimHash = (text) => {
  const h = crypto.createHash("sha256");
  for (const t of nimTokens(text)) { h.update(t); h.update("\u0000"); }
  return h.digest("hex").slice(0, 16);
};

const NIM_DECL = /^(?:proc|func|iterator|template|macro|method|converter|var|let|const|type)\s+`?([A-Za-z_][A-Za-z0-9_]*)/;

// name -> [source text, ...] for one Nim file's top-level declarations.
const nimDeclsOf = (src) => {
  const out = new Map();
  const lines = src.split("\n");
  for (let i = 0; i < lines.length; i++) {
    const m = NIM_DECL.exec(lines[i]);
    if (!m) continue;
    let j = i + 1;
    while (j < lines.length && (lines[j] === "" || /^\s/.test(lines[j]))) j++;
    if (!out.has(m[1])) out.set(m[1], []);
    out.get(m[1]).push(lines.slice(i, j).join("\n"));
    i = j - 1;
  }
  return out;
};

const declsCache = new Map();
// name -> [source text, ...] for one file's top-level declarations.
const declsOf = (file) => {
  if (declsCache.has(file)) return declsCache.get(file);
  const src = fs.readFileSync(path.join(root, file), "utf8");
  if (file.endsWith(".nim")) {
    const out = nimDeclsOf(src);
    declsCache.set(file, out);
    return out;
  }
  const sf = ts.createSourceFile(file, src, ts.ScriptTarget.Latest, true);
  const out = new Map();
  const add = (name, node) => {
    if (!out.has(name)) out.set(name, []);
    out.get(name).push(node.getText(sf));
  };
  for (const st of sf.statements) {
    if (ts.isVariableStatement(st)) {
      for (const d of st.declarationList.declarations)
        if (ts.isIdentifier(d.name)) add(d.name.text, d);
    } else if (ts.isFunctionDeclaration(st) && st.name) {
      add(st.name.text, st);
    } else if (ts.isExpressionStatement(st) && ts.isCallExpression(st.expression)) {
      const c = st.expression;
      if (ts.isPropertyAccessExpression(c.expression) &&
          c.expression.name.text === "addEventListener" &&
          c.arguments[0] && ts.isStringLiteral(c.arguments[0])) {
        add("on:" + c.arguments[0].text, st);
      }
    }
  }
  declsCache.set(file, out);
  return out;
};

const MODEL_DIRS = ["WebState", "DesktopState"];

// { "Dir/Model": { "file#name": hash } } from every `-- @models` line.
const current = () => {
  const res = {};
  const missing = [];
  const files = MODEL_DIRS.flatMap((d) => !fs.existsSync(path.join(here, d)) ? [] :
    fs.readdirSync(path.join(here, d)).filter((f) => f.endsWith(".lean")).sort().map((f) => `${d}/${f}`));
  for (const f of files) {
    const model = f.replace(/\.lean$/, "");
    const lines = fs.readFileSync(path.join(here, f), "utf8").split("\n");
    for (const line of lines) {
      const m = /^-- @models (\S+): (.+)$/.exec(line.trim());
      if (!m) continue;
      const [, file, names] = m;
      const decls = declsOf(file);
      for (const name of names.trim().split(/\s+/)) {
        const texts = decls.get(name);
        if (!texts) { missing.push(`${model}: ${file} has no top-level ${name}`); continue; }
        const hash = file.endsWith(".nim") ? nimHash : tokenHash;
        (res[model] ??= {})[`${file}#${name}`] = hash(texts.join("\n"));
      }
    }
  }
  return { res, missing };
};

const { res, missing } = current();
const stamped = JSON.parse(fs.readFileSync(anchorsFile, "utf8"));
const upd = process.argv.indexOf("--update");
if (upd >= 0) {
  const only = process.argv.slice(upd + 1);
  const picked = (m) => only.length === 0 || only.some((o) => m === o || m.startsWith(o + "/"));
  const bad = missing.filter((x) => picked(x.split(":")[0]));
  if (bad.length) {
    console.error("cannot stamp; anchors name code that does not exist:\n  " + bad.join("\n  "));
    process.exit(1);
  }
  const out = {};
  for (const m of [...new Set([...Object.keys(stamped), ...Object.keys(res)])].sort()) {
    const v = picked(m) ? res[m] : stamped[m];
    if (v) out[m] = v;
  }
  fs.writeFileSync(anchorsFile, JSON.stringify(out, null, 2) + "\n");
  const n = Object.values(out).reduce((a, m) => a + Object.keys(m).length, 0);
  console.log(`anchors.json: ${n} anchors across ${Object.keys(out).length} models`);
  process.exit(0);
}

const stale = new Map();
const note = (model, why) => { if (!stale.has(model)) stale.set(model, []); stale.get(model).push(why); };
for (const m of missing) note(m.split(":")[0], m.slice(m.indexOf(":") + 2));
for (const model of new Set([...Object.keys(res), ...Object.keys(stamped)])) {
  const now = res[model] || {}, then = stamped[model] || {};
  for (const k of new Set([...Object.keys(now), ...Object.keys(then)])) {
    if (!(k in then)) note(model, `${k} is new (not stamped)`);
    else if (!(k in now)) { if (!missing.some((x) => x.startsWith(model))) note(model, `${k} no longer listed`); }
    else if (now[k] !== then[k]) note(model, `${k} changed`);
  }
}
if (stale.size) {
  console.error("Lean models out of date with the code they model:");
  for (const [model, why] of stale) console.error(`  formal/${model}.lean\n    - ${why.join("\n    - ")}`);
  console.error("Model those machines again from the current code (formal/README.md), then\n" +
                "run: node formal/anchors.mjs --update <model>");
  process.exit(1);
}
console.log(`anchors: ${Object.keys(res).length} models match the code they model`);
