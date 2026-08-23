# gbgate — two-build byte-identical framebuffer gate for the GB/GBC core

A reduced stand-in for the `tools/gbfuzz` library sweep for machines without the
GB/GBC library on disk: builds two revisions of `dingbat_bench` side by side and compares
their per-frame framebuffer hash streams over whatever ROMs the machine has. A regression
gate, not a correctness oracle — it says two builds render the same frames, never that
either is right.

    tools/gbgate/build.sh <ref-A> <ref-B> <workdir>
    tools/gbgate/sweep.sh <workdir> <roms.txt> <frames> <warmup> [input-script]
    tools/gbgate/shot.sh  <workdir> <rom> <frame> <out-prefix> [input-script]

`roms.txt` is one absolute ROM path per line (`#` comments; spaces allowed). `sweep.sh`
writes `<workdir>/results.tsv` (`rom<TAB>status<TAB>first-frame`, status `IDENTICAL` /
`DIVERGE` / `TIMEOUT` / `ERROR`) and keeps hash streams under `<workdir>/hashes/`.
`shot.sh` dumps frame N from both builds (`DINGBAT_BENCH_DUMP`) as PNG and reports whether
they are pixel-identical.

Hygiene built in: ROMs are symlinked into a per-build `roms/` directory (`mbc.nim` derives
the `.sav` path from the ROM path, so build A's saves cannot feed build B) and `.sav`
files are deleted before every ROM; each build runs under its own `TMPDIR`; the list is
read with `read -r`; the watchdog redirects the child's stdout to a file and polls, so a
hung ROM cannot wedge the harness.
