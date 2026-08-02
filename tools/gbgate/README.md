# gbgate — two-build byte-identical framebuffer gate for the GB/GBC core

A reduced stand-in for the `tools/gbfuzz` library sweep, for machines that do
not have the 2,613-title GB/GBC library on disk. It builds two revisions of
`dingbat_bench` side by side and compares their per-frame framebuffer hash
streams over whatever real ROMs the machine does have.

This is a *regression gate*, not a correctness oracle: it can only tell you
that two builds render the same frames, never that either is right.

## Use

    tools/gbgate/build.sh <ref-A> <ref-B> <workdir>
    tools/gbgate/sweep.sh <workdir> <roms.txt> <frames> <warmup> [input-script]
    tools/gbgate/shot.sh  <workdir> <rom> <frame> <out-prefix> [input-script]

`roms.txt` is one absolute ROM path per line (`#` comments allowed). Paths may
contain spaces; the scripts never word-split them.

## Hygiene this encodes

Both of these have burned this project before, so they are built in rather
than left to the caller:

* ROMs are **symlinked** into a per-build `roms/` directory, never copied, and
  each build gets its own. `mbc.nim` derives the `.sav` path from the ROM path,
  so a battery-backed game writes its save next to the *symlink* — which keeps
  build A's saves from feeding build B's next run. `sweep.sh` deletes both
  builds' `.sav` files before every ROM.
* Each build runs under its own `TMPDIR`.
* The ROM list is read with `read -r`, not `xargs`/`for` over word-split
  output, so a name with a space cannot truncate the sweep.
* The watchdog redirects the child's stdout to a file and polls; it never
  shares a pipe with the child, so a hung ROM cannot wedge the harness.

## Output

`sweep.sh` writes `<workdir>/results.tsv`: `rom<TAB>status<TAB>first-frame`,
where status is `IDENTICAL`, `DIVERGE`, `TIMEOUT`, or `ERROR`, and prints the
same as it goes. Hash streams are kept under `<workdir>/hashes/` so a
divergence can be re-examined without re-running.

`shot.sh` dumps frame N from both builds (`DINGBAT_BENCH_DUMP`) and converts
the raw BGR555 framebuffers to PNG, reporting whether they are pixel-identical.
