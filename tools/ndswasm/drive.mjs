// node drive.mjs NDSRUN_JS WORKLOAD [extra ndsrun args...]
// Runs the wasm ndsrun (tools/ndswasm/build.sh) on a workload in V8, the
// files written into MEMFS, and reports the node process's host
// instructions / cycles over the timed frames (macOS: the `rusage` helper,
// cc -O2 -o rusage rusage.c). DINGBAT_NDS_NO_BLOCKS is passed through.
// $NDSWASM_DATA holds the states and press lists (docs/nds/blockcache.md,
// "Method"), $DINGBAT_NDS_BIOS the BIOS and firmware dumps.
import { readFileSync } from 'node:fs';
import { execFileSync } from 'node:child_process';
import { createRequire } from 'node:module';
import path from 'node:path';

const S = process.env.NDSWASM_DATA;
const BIOS = process.env.DINGBAT_NDS_BIOS;
const HOME = process.env.HOME;
const RUSAGE = process.env.NDSWASM_RUSAGE || path.join(path.dirname(new URL(import.meta.url).pathname), 'rusage');
const W = {
  gs: [`${HOME}/.cache/dingbat-nds/GoldenSunDarkDawn.nds`, `${S}/gs3000.st`, 3600, `${S}/gs_press.txt`],
  ss7: [`${HOME}/.cache/dingbat-nds/PokemonSoulSilver.nds`, `${S}/ss7100.st`, 7700, `${S}/ss_press.txt`],
  ss10: [`${HOME}/.cache/dingbat-nds/PokemonSoulSilver.nds`, `${S}/ss10000.st`, 10600, `${S}/ss_press.txt`],
};
const [jsPath, wl, ...extra] = process.argv.slice(2);
const [rom, st, to, press] = W[wl];
const require = createRequire(import.meta.url);
const create = require(path.resolve(jsPath));
let cyc = 0;
const M = await create({
  // the environment is read as the runtime starts: set it before that
  preRun: [(m) => { if (process.env.DINGBAT_NDS_NO_BLOCKS) m.ENV.DINGBAT_NDS_NO_BLOCKS = process.env.DINGBAT_NDS_NO_BLOCKS; }],
  print: (s) => console.log(s),
  printErr: (s) => console.error(s),
  ndsrunHost: (k) => {
    if (k === 1) return cyc;
    const [i, c] = execFileSync(RUSAGE, [String(process.pid)]).toString().trim().split(' ').map(Number);
    cyc = c;
    return i;
  },
});
M.FS.mkdir('/bios');
for (const f of ['bios9.bin', 'bios7.bin', 'firmware.bin']) M.FS.writeFile(`/bios/${f}`, readFileSync(`${BIOS}/${f}`));
M.FS.writeFile('/rom.nds', readFileSync(rom));
M.FS.writeFile('/st', readFileSync(st));
M.callMain(['/rom.nds', '--bios', '/bios', '--rtc', '2004-01-01', '--press', readFileSync(press, 'utf8').trim(),
  '--state-load', '/st', '--frames', String(to), '--out', '/out.png', ...extra]);
