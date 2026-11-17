#!/usr/bin/env node
// node tools/status/validate.mjs [web/status.json]: prints what is wrong with
// it (rules.mjs) and exits 1 on any error. Run by the web tests and by the
// Pages deploy, so a broken file never goes out.

import { readFileSync } from "node:fs";
import { validate } from "./rules.mjs";

const file = process.argv[2] || new URL("../../web/status.json", import.meta.url).pathname;
let doc;
try {
  doc = JSON.parse(readFileSync(file, "utf8"));
} catch (e) {
  console.error(`${file}: not valid JSON: ${e.message}`);
  process.exit(1);
}
const { errors, warnings } = validate(doc);
for (const w of warnings) console.log(`warning: ${w.path || "(top)"}: ${w.msg}`);
for (const e of errors) console.error(`error: ${e.path || "(top)"}: ${e.msg}`);
console.log(`${file}: ${errors.length} error(s), ${warnings.length} warning(s)`);
process.exit(errors.length ? 1 : 0);
