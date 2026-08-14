#!/usr/bin/env node
// Generates web/types/em.d.ts — ambient type declarations for the wasm/JS
// boundary — by parsing `{.exportc.}` proc signatures out of
// src/dingbat_wasm.nim. Emscripten exposes each exported proc on the global
// `Module` object as `_<name>`; every parameter and return type at that
// boundary is a 32-bit integer / pointer / float scalar, i.e. `number` on the
// JS side (cstring args are char pointers when called directly; use
// Module.ccall to pass JS strings).
//
// Usage:
//   node web/types/gen-emdts.mjs           # rewrite web/types/em.d.ts
//   node web/types/gen-emdts.mjs --check   # exit 1 if em.d.ts is stale
//
// No dependencies; deterministic output (declarations are emitted in source
// order of dingbat_wasm.nim).

import { readFileSync, writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const here = dirname(fileURLToPath(import.meta.url));
const nimPath = join(here, "..", "..", "src", "dingbat_wasm.nim");
const outPath = join(here, "em.d.ts");

const nim = readFileSync(nimPath, "utf8");

// Nim scalar type -> JS-boundary type. Everything crossing the wasm ABI is a
// number (pointers included). Unknown types are an error so new signatures
// get reviewed rather than silently mistyped.
const TYPE_MAP = {
  cint: "number",
  int32: "number",
  uint32: "number",
  cdouble: "number",
  float32: "number",
  pointer: "number",
  cstring: "number",
};

function mapType(nimType, ctx) {
  const t = TYPE_MAP[nimType.trim()];
  if (!t) {
    console.error(`gen-emdts: unmapped Nim type "${nimType}" in ${ctx}`);
    process.exit(2);
  }
  return t;
}

// Match `proc name(params) [: ret] {.exportc.}` — params may span lines but
// contain no nested parentheses in this codebase.
const procRe =
  /proc\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)\s*(?::\s*([A-Za-z_][A-Za-z0-9_]*))?\s*\{\.exportc\.\}/g;

const decls = [];
let m;
while ((m = procRe.exec(nim)) !== null) {
  const [, name, rawParams, rawRet] = m;
  const params = [];
  const paramSrc = rawParams.replace(/\s+/g, " ").trim();
  if (paramSrc.length > 0) {
    for (const group of paramSrc.split(";")) {
      const [namesPart, typePart] = group.split(":");
      if (typePart === undefined) {
        console.error(`gen-emdts: cannot parse params of proc ${name}`);
        process.exit(2);
      }
      const jsType = mapType(typePart, `proc ${name}`);
      for (const p of namesPart.split(",")) {
        params.push(`${p.trim()}: ${jsType}`);
      }
    }
  }
  const ret = rawRet ? mapType(rawRet, `proc ${name} return`) : "void";
  decls.push(`  _${name}?(${params.join(", ")}): ${ret};`);
}

if (decls.length === 0) {
  console.error("gen-emdts: found no {.exportc.} procs — wrong source path?");
  process.exit(2);
}

const header = `// GENERATED FILE — do not edit by hand.
// Produced by: node web/types/gen-emdts.mjs
// Source of truth: src/dingbat_wasm.nim ({.exportc.} procs).
// CI runs \`node web/types/gen-emdts.mjs --check\` to keep this in sync.

/**
 * The emscripten Module object for the non-modularized em.js build.
 * Wasm exports appear as optional \`_name\` members: they exist only after the
 * runtime has initialized, which is why the app code guards on them.
 * All boundary values are numbers (pointers/ints/floats); cstring parameters
 * are char pointers when called directly — use ccall to pass JS strings.
 */
interface EmscriptenModule {
  // --- emscripten runtime members used by the front-end ---
  canvas?: HTMLCanvasElement | null;
  memory?: WebAssembly.Memory;
  HEAPU8?: Uint8Array;
  calledRun?: boolean;
  onRuntimeInitialized?: () => void | Promise<void>;
  instantiateWasm?(
    imports: WebAssembly.Imports,
    successCallback: (instance: WebAssembly.Instance, module: WebAssembly.Module) => void
  ): object;
  ccall?(
    name: string,
    returnType: string | null,
    argTypes: string[],
    args: unknown[]
  ): any;
  cwrap?(name: string, returnType: string | null, argTypes: string[]): Function;
  UTF8ToString?(ptr: number): string;
  _malloc?(size: number): number;
  _free?(ptr: number): void;

  // --- wasm exports generated from src/dingbat_wasm.nim ---
`;

const footer = `}

declare var Module: EmscriptenModule;

/** Emscripten's in-memory filesystem (global in the non-modularized build). */
declare var FS: {
  open(path: string, flags: string): object;
  write(stream: object, buf: Uint8Array, offset: number, length: number, position?: number): number;
  close(stream: object): void;
  read(stream: object, buf: Uint8Array, offset: number, length: number, position?: number): number;
  readFile(path: string): Uint8Array;
  unlink(path: string): void;
};
`;

const output = header + decls.join("\n") + "\n" + footer;

if (process.argv.includes("--check")) {
  let current = "";
  try {
    current = readFileSync(outPath, "utf8");
  } catch {
    console.error("gen-emdts: web/types/em.d.ts is missing — run: node web/types/gen-emdts.mjs");
    process.exit(1);
  }
  if (current !== output) {
    console.error(
      "gen-emdts: web/types/em.d.ts is stale (dingbat_wasm.nim exports changed) — run: node web/types/gen-emdts.mjs"
    );
    process.exit(1);
  }
  console.log(`gen-emdts: em.d.ts up to date (${decls.length} exports)`);
} else {
  writeFileSync(outPath, output);
  console.log(`gen-emdts: wrote em.d.ts (${decls.length} exports)`);
}
