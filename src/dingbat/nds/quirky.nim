## The switches every DS emulation module's `{.push quirky: nds_quirky.}`
## reads, and the renderers' unchecked regions (docs/nds/perf.md,
## "Error-flag checks").
##
## Quirky, a call does not test Nim's error flag afterwards, so a check that
## fails goes on (the out-of-range access included) until a caller outside
## the core tests it: a wild index is a SIGSEGV or a stray write instead of
## an IndexDefect. The core's own state cannot make one; a loaded state is
## the outside input that could, which is why the loader range-checks every
## field the core indexes, shifts or divides with (savestate.nim `after_load`).
## tools/statefuzz.nim finds the ones it misses, built with
## -d:nds_quirky=false so that a fault is reported where it happens, and
## -d:nds_render_checks so that the 2D line renderer and the 3D per-dot path,
## which run without index checks in every build (their indexes are masked
## or clamped), are checked too.

const nds_quirky* {.booldefine.} = true
const nds_render_checks* {.booldefine.} = false
