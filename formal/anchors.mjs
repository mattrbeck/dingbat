// Which Lean models no longer describe the JS they model.
//
// The proofs in formal/ are about models, and nothing in `lake build` reads
// the JS: a change to loadRom leaves GameLifecycle.lean proving things about
// code that no longer exists. The models are an audit's snapshot, not a
// contract every commit keeps (the regression tests in web/tests/ are that),
// so this is not a CI gate: run it when starting the next audit, and it says
// which machines changed since the last one and need modelling again. Each
// model names what it models, one line per file:
//
//   -- @models web/index.js: loadRom launchRom on:visibilitychange
//
// A name is a top-level `const`/`let`/`function` declaration, or `on:<event>`
// for every top-level `x.addEventListener("<event>", ...)` together. This
// script hashes each one's tokens (comments and whitespace do not count, so
// rewording a comment never trips it) and compares with anchors.json.
//
//   node formal/anchors.mjs            list the stale models (exit 1 if any)
//   node formal/anchors.mjs --update   stamp, once the models match the JS again
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

const declsCache = new Map();
// name -> [source text, ...] for one JS file's top-level declarations.
const declsOf = (file) => {
  if (declsCache.has(file)) return declsCache.get(file);
  const src = fs.readFileSync(path.join(root, file), "utf8");
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

// { model: { "file#name": hash } } from every `-- @models` line.
const current = () => {
  const dir = path.join(here, "WebState");
  const res = {};
  const missing = [];
  for (const f of fs.readdirSync(dir).filter((f) => f.endsWith(".lean")).sort()) {
    const model = f.replace(/\.lean$/, "");
    const lines = fs.readFileSync(path.join(dir, f), "utf8").split("\n");
    for (const line of lines) {
      const m = /^-- @models (\S+): (.+)$/.exec(line.trim());
      if (!m) continue;
      const [, file, names] = m;
      const decls = declsOf(file);
      for (const name of names.trim().split(/\s+/)) {
        const texts = decls.get(name);
        if (!texts) { missing.push(`${model}: ${file} has no top-level ${name}`); continue; }
        (res[model] ??= {})[`${file}#${name}`] = tokenHash(texts.join("\n"));
      }
    }
  }
  return { res, missing };
};

const { res, missing } = current();
if (process.argv.includes("--update")) {
  if (missing.length) {
    console.error("cannot stamp; anchors name code that does not exist:\n  " + missing.join("\n  "));
    process.exit(1);
  }
  fs.writeFileSync(anchorsFile, JSON.stringify(res, null, 2) + "\n");
  const n = Object.values(res).reduce((a, m) => a + Object.keys(m).length, 0);
  console.log(`anchors.json: ${n} anchors across ${Object.keys(res).length} models`);
  process.exit(0);
}

const stamped = JSON.parse(fs.readFileSync(anchorsFile, "utf8"));
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
  console.error("Lean models out of date with the JS they model:");
  for (const [model, why] of stale) console.error(`  formal/WebState/${model}.lean\n    - ${why.join("\n    - ")}`);
  console.error("Model those machines again from the current code (formal/README.md), then\n" +
                "run: node formal/anchors.mjs --update");
  process.exit(1);
}
console.log(`anchors: ${Object.keys(res).length} models match the JS they model`);
