# mGBA suite per-row golden captures

Phase-0 safety net for the prefetch-model rewrite (`docs/prefetch-model-rewrite.md`).
These TSVs record **every** Timing/DMA/… row the mGBA suite ROM prints — passing and
failing — so any change to the timing model is judged by a per-row `diff`, never by the
aggregate `END: pass/total` line (a silent regression among ~7000 rows is invisible in
the aggregate).

Captured at `main` @ **a6ec55e** (code identical to 3a65b78, which only adds the plan
doc). Baseline: **HLE 6898 / LLE 6897** pass out of 7008 emitted rows.

- `mgba_rows_hle.tsv` — HLE BIOS (default; no BIOS file needed).
- `mgba_rows_lle.tsv` — genuine BIOS (md5 `a860e8c0…`), i.e. `tests/roms/gba_bios.bin`.

Columns: `suite  ord  name  status  ours  expected  delta`. Rows are keyed by
`(suite, ord)` — the ordinal is program order within a suite and is stable across model
changes (a change alters values, not which tests run), so a flipped row keeps its key.
Passing rows have `ours==expected` by definition, so a value change on a passing row
shows up as a `PASS -> FAIL` flip. `delta = ours - expected` is filled only for the
decimal Timing cycle-count rows.

## Workflow

Tool: `tests/mgba_rowdiff.py` (stdlib Python 3, no build).

```sh
# After a code change, re-capture both configs:
python3 tests/mgba_rowdiff.py capture --harness ./dingbat_test \
    --rom /tmp/dingbat-test-roms/mgba-suite.gba --out /tmp/new_hle.tsv
python3 tests/mgba_rowdiff.py capture --harness ./dingbat_test \
    --rom /tmp/dingbat-test-roms/mgba-suite.gba \
    --bios tests/roms/gba_bios.bin --out /tmp/new_lle.tsv

# Diff against golden (exit 1 if any row changed):
python3 tests/mgba_rowdiff.py diff tests/golden/mgba_rows_hle.tsv /tmp/new_hle.tsv
python3 tests/mgba_rowdiff.py diff tests/golden/mgba_rows_lle.tsv /tmp/new_lle.tsv

# Restrict to the suites under active work:
python3 tests/mgba_rowdiff.py diff tests/golden/mgba_rows_hle.tsv /tmp/new_hle.tsv \
    --only 'Timing tests,DMA tests'
```

The diff prints per-suite totals, then classifies every changed row as **REGRESSED**
(PASS→FAIL — the thing to fear), **FIXED** (FAIL→PASS — the goal), **VALUE CHANGED**
(still failing, numbers moved), or **STRUCTURAL** (row added/removed — suite changed).

### Known non-regression differences (do not chase)

Diffing HLE↔LLE golden surfaces exactly four rows, all documented as artifacts in the
`gba-timing-accuracy-2026-07` memory — not model bugs:

- `I/O read #106 DMA3CNT_HI` — LLE regresses to `0x7FE0 vs 0xFFE0`; an immediate-DMA
  3-cycle-window margin test whose pass/fail is print-length-coupled (same class as the
  savprintf `-SRAM` luck), not the OOB logic.
- `Misc #4/#7/#8 H-blank bit start` — the suite's own *expected* values shift with log
  length; both configs already fail these.

When re-verifying the rewrite, regenerate these goldens only after confirming any new
row-diffs are intended.
