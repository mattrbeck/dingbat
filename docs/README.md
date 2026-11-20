# Documentation index

One line per document: what it is for and who reads it. Scores live only in
`tests/results*.md`; every other file points at them.

## Using dingbat

- [usage.md](usage.md) — loading ROMs, BIOS files, saves, GB renderer choice.
- [features.md](features.md) — what the front-ends and the emulated systems support.
- [link-usage.md](link-usage.md) — local 2P, online room codes, native TCP link: the practical guide.
- [run-ahead.md](run-ahead.md) — the run-ahead latency setting and what it costs.
- [known-bugs.md](known-bugs.md) — bugs found and understood but not yet fixed.
- [nds/beta.md](nds/beta.md) — DS Beta: the switch that turns on `.nds` games, and what works.

## Building and releasing

- [building.md](building.md) — native, WebAssembly and Windows cross-builds. Contributors.
- [../THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md) — licences of everything compiled into the binaries and the two derived models. Whoever ships a release.
- [manual-verification.md](dev/manual-verification.md) — hands-on checks the harnesses cannot run (Drive, deployed https, devices). Whoever ships a release.

# Developer reference

Everything below lives in [`dev/`](dev/) (the DS core's notes in [`nds/`](nds/)):
design notes, hardware evidence and test triage for people working on dingbat.

## Architecture and subsystems

- [nds/spec.md](nds/spec.md) — the DS core: spec, prototype map, and the way into the rest of `nds/`. DS maintainers.
- [multiplayer.md](dev/multiplayer.md) — link-cable layers, rollback netplay and the network wire format. Link/netplay maintainers.
- [speculative-rollback-handoff.md](dev/speculative-rollback-handoff.md) — speculative execution over the network link: design and bench hooks. Netplay maintainers.
- [security.md](dev/security.md) — what dingbat takes from outside (ROMs, states, Drive, a link friend), what guards each, and what is open. Anyone touching those paths.
- [savestate_compat.md](dev/savestate_compat.md) — the `.state` container, per-core payload revisions, compatibility rules. Anyone touching serialized state.
- [sgb.md](dev/sgb.md) — the Super Game Boy adapter: transport, commands, rendering, save state. GB maintainers.
- [fifo_ppu_changes.md](dev/fifo_ppu_changes.md) — the GB FIFO PPU model against Pan Docs' pixel FIFO. GB PPU maintainers.
- [lcd_response.md](dev/lcd_response.md) — the LCD panel response model (ghosting) and its test. Video maintainers.
- [lcd_ghost_delta.md](dev/lcd_ghost_delta.md) — parked: LCD ghosting per upscale-filter cell. Video maintainers.
- [ui-redesign-spec.md](dev/ui-redesign-spec.md) — the earlier web UI redesign plan; its §0 Do-not-break table still holds. Web maintainers.
- [home-screen.md](dev/home-screen.md) — the web home screen: its states, Resume and Play, sessions and their pictures, flights, the account slot. Web maintainers.
- [web_audio_pacing.md](dev/web_audio_pacing.md) — the web audio scheduling-lead servo and how to measure it. Web maintainers.
- [hle-bios-shortcomings.md](dev/hle-bios-shortcomings.md) — what the built-in GBA HLE BIOS does not do. GBA maintainers.
- [gba-rtc.md](dev/gba-rtc.md) — the GBA cartridge clock: host time unless a game sets it, the battery-save RTC trailer, behaviour next to mGBA and real carts. GBA maintainers, anyone moving saves between emulators.
- [ios-app.md](dev/ios-app.md) — the native iOS app: what matches the web front-end, native differences, what is left off. iOS maintainers.
- [desktop-presenter.md](dev/desktop-presenter.md) — how the desktop app draws: OpenGL 3.3, Metal on macOS, one shader for both, how they compare. Desktop maintainers.
- [ios-display-link.md](dev/ios-display-link.md) — iOS display pacing: CADisplayLink against CAMetalDisplayLink, measured. iOS maintainers.
- [ios-feasibility.md](dev/ios-feasibility.md) — the iOS core build and what is proven. Anyone reviving the iOS port.
- [performance.md](dev/performance.md) — harnesses, measurement rules, what is known about cost. Anyone doing perf work.
- [settings-cost.md](dev/settings-cost.md) — what each web setting costs per frame, measured through the shipping paths. Web perf work.
- [gb_oam_dma_cost.md](dev/gb_oam_dma_cost.md) — measuring a change on the GB CPU bus hot path (the inline cliff). GB perf work.
- [research_ppu_hotspots.md](dev/research_ppu_hotspots.md) — GBA PPU cost ceilings per component on real gameplay states. GBA perf work.
- [research_waitloop_tracer.md](dev/research_waitloop_tracer.md) — the dynamic waitloop tracer that did not land, and why. GBA perf work.

## Hardware behaviour: evidence and open questions

- [gb-derivations.md](dev/gb-derivations.md) — claim, evidence, constant: one entry per non-obvious modelled GB/GBA behaviour. Anyone changing a timing knob.
- [gb-hardware-revisions.md](dev/gb-hardware-revisions.md) — the `GbRevision` → `GbQuirks` axis, what each flag is pinned by, what a revision cannot fix. GB maintainers.
- [gb-mealybug-sources.md](dev/gb-mealybug-sources.md) — Mealybug Tearoom read from its `.asm`: the decode tables and per-test assertions. GB PPU work.
- [samesuite-apu.md](dev/samesuite-apu.md) — SameSuite APU read from its `.asm` and the GB APU model built on it. GB APU work.
- [pandocs-audit.md](dev/pandocs-audit.md) — where dingbat disagrees with Pan Docs, ranked, with evidence or `Assumed`. GB maintainers.
- [pandocs-upstream.md](dev/pandocs-upstream.md) — corrections draftable for gbdev/pandocs, and what hardware must settle first. Whoever files them.
- [gbatek-upstream.md](dev/gbatek-upstream.md) — the GBA counterpart: open-bus and DMA-grant corrections hardware has settled, each with the payload that reproduces it, plus what is not settled and why. Whoever files them.
- [oracles.md](dev/oracles.md) — behaviours pinned only by comparison with another emulator: the complete list, each a probe candidate. Anyone citing evidence.
- [hwprobe-questions.md](dev/hwprobe-questions.md) — the ranked catalogue of hardware questions the suites cannot settle, with the probe for each. Whoever plans a hardware session.
- [hwprobe.md](dev/hwprobe.md) — the `gbedge`/`gbaedge` probe ROMs: page tables and the photograph protocol. Hardware sessions.
- [hwprobe-results-agb.md](dev/hwprobe-results-agb.md) — what the AGS-001 sessions said, page by page. GBA maintainers.
- [hwprobe-sst.md](dev/hwprobe-sst.md) — the SingleStepTests ARM7TDMI disagreements, asked of an AGB SP. GBA CPU work.
- [cycle-hunt-method.md](dev/cycle-hunt-method.md) — the order to chase a cycle-level timing disagreement in. GBA timing work.
- [flashcart-runbook.md](dev/flashcart-runbook.md) — the GB flashcart session kit, rules, and every GB hardware result to date (this is the session log by design). Hardware sessions.
- [gb-hardware-session-runbook.md](dev/gb-hardware-session-runbook.md) — how to run the `tools/gbprobe/` carts on real hardware and what each outcome decides. Hardware sessions.
- [gb-probe-oracle-results-2026-08-11.md](dev/gb-probe-oracle-results-2026-08-11.md) — per probe cart: what it measures, dingbat's prediction, hardware status. Hardware sessions.

## Test suites: sources, scoring, triage

- [../tests/README.md](../tests/README.md) — the harnesses, how each suite is scored, the device axis, the gambatte suite, hazards. Anyone running tests.
- [../tests/results.md](../tests/results.md), [../tests/results_gambatte.md](../tests/results_gambatte.md), [../tests/results_mgba_suite.md](../tests/results_mgba_suite.md) — generated baselines (per suite, per gambatte row, per mGBA-suite row). Never edited by hand.
- [gb-test-suite-sources.md](dev/gb-test-suite-sources.md) — per GB suite: upstream, silicon it was verified on, and the hardware claims its sources state. GB maintainers.
- [gb-failure-triage.md](dev/gb-failure-triage.md) — every red GB row grouped by mechanism, with the knob, what would close it, refuted models, closed buckets. GB timing work.
- [mgba-suite-verdicts.md](dev/mgba-suite-verdicts.md) — why each failing mGBA-suite row fails. GBA timing work.
- [playtest-bugs.md](dev/playtest-bugs.md) — one entry per bug the cross-emulator playtest harness found, by § number. Anyone citing a §.
- [../tests/golden/README.md](../tests/golden/README.md) — per-row mGBA-suite golden captures for diff-based timing work. GBA timing work.
- [../tests/roms/expected/README.md](../tests/roms/expected/README.md) — hardware transcriptions of the probe ROMs. Hardware sessions.
- [../tests/roms/hwverified/README.md](../tests/roms/hwverified/README.md) — self-judging GBA ROMs carrying hardware-verified expectations. GBA maintainers.
- [../tools/mp2kprobe/README.md](../tools/mp2kprobe/README.md) — probe songs played by the game's own MP2K driver: what the mixer does, to the byte. Audio HLE work.
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

- [../notes/README.md](dev/notes/README.md) — architecture map, subsystem state, open items.
