# docs/

Two kinds of file live here. **Live references** are kept current and are meant to be
read before touching the area they cover. **Archives** record how something was
measured or why an approach was refused; they are dated, they are not maintained, and
their conclusions describe the tree as it stood. Check an archive's claims against the
code before acting on them.

Derivations for individual constants live at the constants themselves, in
`src/dingbat/gb/gb.nim` and `fifo_ppu.nim`, not here.

## Using dingbat

| doc | what it is |
|---|---|
| [usage.md](usage.md) | running the emulator |
| [building.md](building.md) | native, wasm and Windows builds |
| [downloads.md](downloads.md) | release artifacts |
| [features.md](features.md) | what is implemented, per system |
| [link-usage.md](link-usage.md) | link cable: how it works and how to use it |
| [speed-mode.md](speed-mode.md) | the low-end-device mode and what it costs |
| [manual-verification.md](manual-verification.md) | checks that no test covers |

## GB/GBC accuracy — live

| doc | what it is |
|---|---|
| [gb-failure-triage.md](gb-failure-triage.md) | **the canonical next-steps list**: every failing bucket, ranked, with what is known about each |
| [gb-test-suite-sources.md](gb-test-suite-sources.md) | what each suite actually measures, and where dingbat disagrees |
| [gb-mealybug-sources.md](gb-mealybug-sources.md) | the mealybug ROMs read from their own source — the band/ruler decoding the PPU work depends on |
| [gb-hardware-revisions.md](gb-hardware-revisions.md) | which behaviours are per-revision, and the axis dingbat does not model |
| [hwprobe-questions.md](hwprobe-questions.md) | ranked list of what dingbat assumes with no hardware evidence |
| [pandocs-audit.md](pandocs-audit.md) | where dingbat disagrees with Pan Docs, with status |
| [pandocs-upstream.md](pandocs-upstream.md) | corrections to send upstream |
| [gb_oam_dma_cost.md](gb_oam_dma_cost.md) | the perf-measurement method and the inline cliff — read before any A/B |

## Hardware sessions

| doc | what it is |
|---|---|
| [flashcart-runbook.md](flashcart-runbook.md) | the kit and the session procedure |
| [gb-hardware-session-runbook.md](gb-hardware-session-runbook.md) | flash-cart day checklist |
| [hwprobe.md](hwprobe.md) | the gbedge.gb / gbaedge.gba probe ROMs |
| [hwprobe-results-agb.md](hwprobe-results-agb.md) | AGB sessions 1 and 2 |
| [gb-probe-oracle-results-2026-08-11.md](gb-probe-oracle-results-2026-08-11.md) | the three experiments read in three emulators |
| [probe-d-tdsel.md](probe-d-tdsel.md) · [probe-e-plan.md](probe-e-plan.md) · [probe-f-window.md](probe-f-window.md) | per-probe shot lists and what each frame decides |

## Networking and link

| doc | what it is |
|---|---|
| [multiplayer.md](multiplayer.md) | local 2P and cross-emulator link |
| [netcode-unification.md](netcode-unification.md) | the netcode map; what was unified and what was deferred |
| [cross-game-trade.md](cross-game-trade.md) | the resolved Pokémon trade bug, its decomp analysis, and the repro harnesses |
| [input-rollback-netplay.md](input-rollback-netplay.md) | rollback design and cross-ROM transmission |
| [run-ahead.md](run-ahead.md) | run-ahead findings |

## Performance

| doc | what it is |
|---|---|
| [performance.md](performance.md) | the running optimization log |
| [research_ppu_next_steps.md](research_ppu_next_steps.md) | what to build next in the PPU |
| [research_firered_perf.md](research_firered_perf.md) | FireRed across native, Chrome and Safari |
| [research_ppu_hotspots.md](research_ppu_hotspots.md) | hotspots across five real-gameplay save states |
| [research_cached_interpreter.md](research_cached_interpreter.md) | why a block cache tops out at +8–12% |

## Front end and platform

| doc | what it is |
|---|---|
| [ios-feasibility.md](ios-feasibility.md) | dingbat as an iPhone app |
| [frontend-gap-analysis.md](frontend-gap-analysis.md) | front-end parity gaps |
| [lcd_ghost_delta.md](lcd_ghost_delta.md) | ghosting × upscale filters, per cell |
| [research_lcd_response.md](research_lcd_response.md) | the panel model that replaced interframe blending |
| [research_savestate_compat.md](research_savestate_compat.md) | save states across emulator updates |
| [research_drive_auth.md](research_drive_auth.md) | Google Drive sign-in |
| [research_web_audio_gaps.md](research_web_audio_gaps.md) | web audio dropouts |

## GBA accuracy

| doc | what it is |
|---|---|
| [mgba-suite-verdicts.md](mgba-suite-verdicts.md) | per-row verdicts on the mGBA suite's failures |
| [research_gba_memory_stall.md](research_gba_memory_stall.md) | the ROM-prefetch timing model |
| [prefetch-model-rewrite.md](prefetch-model-rewrite.md) | the occupancy-model rewrite |
| [hle-bios-shortcomings.md](hle-bios-shortcomings.md) | deliberate HLE gaps |
| [research_sgb.md](research_sgb.md) | Super Game Boy borders and palettes |

## Archives — dated, not maintained

`gb-derivations.md` · `gb-renderer-structure-research-2026-08-10.md` ·
`gb-bundle-measurement-2026-08-10.md` · `research_dma_bios_rom.md` ·
`research_timer_irq.md` · `research_failing_rows_breakdown.md` ·
`research_sram_unaligned.md` · `research_sio_timing.md` ·
`research_midframe_state.md` · `research_waitloop_tracer.md` ·
`research_dshba_comparison.md` · `speculative-rollback-handoff.md` ·
`phase3b-plan.md` (implemented 2026-07-11)
