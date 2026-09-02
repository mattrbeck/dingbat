# Documentation index

One line per document: what it is for and who reads it. Scores live only in
`tests/results*.md`; every other file points at them.

## Using dingbat

- [downloads.md](downloads.md) — prebuilt desktop binaries per platform. Players.
- [usage.md](usage.md) — loading ROMs, BIOS files, saves, GB renderer choice. Players.
- [features.md](features.md) — what both front-ends and both systems support. Players, contributors.
- [link-usage.md](link-usage.md) — local 2P, online room codes, native TCP link: the practical guide. Players.
- [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) — licences of everything compiled into the binaries and the two derived models. Whoever ships a release.
- [building.md](building.md) — native, WebAssembly and Windows cross-builds. Contributors.
- [speed-mode.md](speed-mode.md) — the one less-accurate switch for low-end devices and what it suspends. Players, web maintainers.
- [run-ahead.md](run-ahead.md) — the run-ahead latency setting and its cost model. Players, web maintainers.
- [manual-verification.md](manual-verification.md) — hands-on checks the harnesses cannot run (Drive, deployed https, devices). Whoever ships a release.

## Architecture and subsystems

- [multiplayer.md](multiplayer.md) — link-cable layers, rollback netplay and the network wire format. Link/netplay maintainers.
- [speculative-rollback-handoff.md](speculative-rollback-handoff.md) — speculative execution over the network link: design and bench hooks. Netplay maintainers.
- [savestate_compat.md](savestate_compat.md) — the `.state` container, per-core payload revisions, compatibility rules. Anyone touching serialized state.
- [sgb.md](sgb.md) — the Super Game Boy adapter: transport, commands, rendering, save state. GB maintainers.
- [fifo_ppu_changes.md](fifo_ppu_changes.md) — the GB FIFO PPU model against Pan Docs' pixel FIFO. GB PPU maintainers.
- [lcd_response.md](lcd_response.md) — the LCD panel response model (ghosting) and its test. Video maintainers.
- [lcd_ghost_delta.md](lcd_ghost_delta.md) — parked: LCD ghosting per upscale-filter cell. Video maintainers.
- [web_audio_pacing.md](web_audio_pacing.md) — the web audio scheduling-lead servo and how to measure it. Web maintainers.
- [hle-bios-shortcomings.md](hle-bios-shortcomings.md) — what the built-in GBA HLE BIOS does not do. GBA maintainers.
- [ios-feasibility.md](ios-feasibility.md) — the iOS core build and what is proven. Anyone reviving the iOS port.
- [performance.md](performance.md) — harnesses, measurement rules, what is known about cost. Anyone doing perf work.
- [gb_oam_dma_cost.md](gb_oam_dma_cost.md) — measuring a change on the GB CPU bus hot path (the inline cliff). GB perf work.
- [research_ppu_hotspots.md](research_ppu_hotspots.md) — GBA PPU cost ceilings per component on real gameplay states. GBA perf work.
- [research_waitloop_tracer.md](research_waitloop_tracer.md) — the dynamic waitloop tracer that did not land, and why. GBA perf work.

## Hardware behaviour: evidence and open questions

- [gb-derivations.md](gb-derivations.md) — claim, evidence, constant: one entry per non-obvious modelled GB/GBA behaviour. Anyone changing a timing knob.
- [gb-hardware-revisions.md](gb-hardware-revisions.md) — the `GbRevision` → `GbQuirks` axis, what each flag is pinned by, what a revision cannot fix. GB maintainers.
- [gb-mealybug-sources.md](gb-mealybug-sources.md) — Mealybug Tearoom read from its `.asm`: the decode tables and per-test assertions. GB PPU work.
- [samesuite-apu.md](samesuite-apu.md) — SameSuite APU read from its `.asm` and the GB APU model built on it. GB APU work.
- [pandocs-audit.md](pandocs-audit.md) — where dingbat disagrees with Pan Docs, ranked, with evidence or `Assumed`. GB maintainers.
- [pandocs-upstream.md](pandocs-upstream.md) — corrections draftable for gbdev/pandocs, and what hardware must settle first. Whoever files them.
- [oracles.md](oracles.md) — behaviours pinned only by comparison with another emulator: the complete list, each a probe candidate. Anyone citing evidence.
- [hwprobe-questions.md](hwprobe-questions.md) — the ranked catalogue of hardware questions the suites cannot settle, with the probe for each. Whoever plans a hardware session.
- [hwprobe.md](hwprobe.md) — the `gbedge`/`gbaedge` probe ROMs: page tables and the photograph protocol. Hardware sessions.
- [hwprobe-results-agb.md](hwprobe-results-agb.md) — what the AGS-001 sessions said, page by page. GBA maintainers.
- [flashcart-runbook.md](flashcart-runbook.md) — the GB flashcart session kit, rules, and every GB hardware result to date (this is the session log by design). Hardware sessions.
- [gb-hardware-session-runbook.md](gb-hardware-session-runbook.md) — how to run the `tools/gbprobe/` carts on real hardware and what each outcome decides. Hardware sessions.
- [gb-probe-oracle-results-2026-08-11.md](gb-probe-oracle-results-2026-08-11.md) — per probe cart: what it measures, dingbat's prediction, hardware status. Hardware sessions.

## Test suites: sources, scoring, triage

- [../tests/README.md](../tests/README.md) — the harnesses, how each suite is scored, the device axis, the gambatte suite, hazards. Anyone running tests.
- [../tests/results.md](../tests/results.md), [../tests/results_gambatte.md](../tests/results_gambatte.md), [../tests/results_mgba_suite.md](../tests/results_mgba_suite.md) — generated baselines (per suite, per gambatte row, per mGBA-suite row). Never edited by hand.
- [gb-test-suite-sources.md](gb-test-suite-sources.md) — per GB suite: upstream, silicon it was verified on, and the hardware claims its sources state. GB maintainers.
- [gb-failure-triage.md](gb-failure-triage.md) — every red GB row grouped by mechanism, with the knob, what would close it, refuted models, closed buckets. GB timing work.
- [mgba-suite-verdicts.md](mgba-suite-verdicts.md) — why each failing mGBA-suite row fails. GBA timing work.
- [../tests/golden/README.md](../tests/golden/README.md) — per-row mGBA-suite golden captures for diff-based timing work. GBA timing work.
- [../tests/roms/expected/README.md](../tests/roms/expected/README.md) — hardware transcriptions of the probe ROMs. Hardware sessions.
- [../tests/roms/hwverified/README.md](../tests/roms/hwverified/README.md) — self-judging GBA ROMs carrying hardware-verified expectations. GBA maintainers.
- [../tests/mp2k_sweep_results/SUMMARY.md](../tests/mp2k_sweep_results/SUMMARY.md) — the MP2K HLE archive sweep over one ROM per title. Audio HLE work.

## Tool kits (`tools/*/README.md`)

- [../tools/gbppu/README.md](../tools/gbppu/README.md) — the GB mode-3 measurement kit: trace flags, family readers, sweeps, the retired-instruction A/B. GB timing work.
- [../tools/gbapu/README.md](../tools/gbapu/README.md) — SameSuite APU rows as raw result bytes per revision. GB APU work.
- [../tools/gbprobe/README.md](../tools/gbprobe/README.md) — the probe ROMs and the harness that runs them through dingbat and two black-box engines. Hardware sessions.
- [../tools/gbprobe/g1_README.md](../tools/gbprobe/g1_README.md) — the g1 halt-lead probe: what to flash, what each reading decides. Hardware sessions.
- [../tools/gbphoto/README.md](../tools/gbphoto/README.md) — reading a Game Boy screen out of a photograph, and validating the read. Hardware sessions.
- [../tools/gbdiff/README.md](../tools/gbdiff/README.md) — differential GB/GBC harness against a second engine (frames, not constants). GB maintainers.
- [../tools/gbgate/README.md](../tools/gbgate/README.md) — two-build byte-identical framebuffer gate for the GB core. Anyone refactoring the GB core.
- [../tools/nbadiff/README.md](../tools/nbadiff/README.md) — GBA audio-sample comparison against a second engine's mixer. GBA audio work.

## Working notes

- [../notes/README.md](../notes/README.md) — architecture map, subsystem state, open items.
