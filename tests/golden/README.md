# mGBA suite per-row golden captures

These TSVs record every row the mGBA suite ROM prints — passing and failing — so a
timing-model change is judged by a per-row diff, never by the aggregate `END: pass/total`
line (a silent regression among ~7000 rows is invisible in the aggregate).

- `mgba_rows_hle.tsv` — HLE BIOS (default).
- `mgba_rows_lle.tsv` — real BIOS (`tests/roms/gba_bios.bin`, md5 `a860e8c0…`).

Columns: `suite  ord  name  status  ours  expected  delta`. Rows are keyed by
`(suite, ord)`; the ordinal is program order within a suite and survives model changes.
`delta = ours - expected` is filled only for the decimal Timing cycle-count rows.

## Workflow

```sh
python3 tests/mgba_rowdiff.py capture --harness ./dingbat_test \
    --rom /tmp/dingbat-test-roms/mgba-suite.gba --out /tmp/new_hle.tsv
python3 tests/mgba_rowdiff.py capture --harness ./dingbat_test \
    --rom /tmp/dingbat-test-roms/mgba-suite.gba --bios tests/roms/gba_bios.bin --out /tmp/new_lle.tsv
python3 tests/mgba_rowdiff.py diff tests/golden/mgba_rows_hle.tsv /tmp/new_hle.tsv   # exit 1 on any change
python3 tests/mgba_rowdiff.py diff tests/golden/mgba_rows_hle.tsv /tmp/new_hle.tsv --only 'Timing tests,DMA tests'
```

The diff classifies each changed row as REGRESSED (PASS→FAIL), FIXED, VALUE CHANGED
(still failing, numbers moved) or STRUCTURAL (row added/removed).

Known HLE↔LLE differences that are not model bugs: `I/O read #106 DMA3CNT_HI` (an
immediate-DMA margin test whose verdict is print-length-coupled) and `Misc #4/#7/#8
H-blank bit start` (the suite's own expected values shift with log length). Regenerate
the goldens only after confirming every new row diff is intended.
