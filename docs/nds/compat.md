# DS homebrew compatibility sweep

What happens when freely distributable DS homebrew -- games, demoscene
productions, emulator ports, tech demos, tools -- runs on dingbat's DS core,
compared run for run with the reference core (`tools/ndsref`, the core
docs/oracles.md names for current libnds builds). Sweep of 2026-10-01 on
branch `nds-compat`.

## The harness: `tools/ndssweep.nim`

    nim c -d:release -d:test_harness --path:src -o:ndssweep tools/ndssweep.nim
    sh tools/ndsref/build.sh
    ./ndssweep ~/.cache/dingbat-nds/roms/homebrew --out OUT --core NAME \
        --bios "$HOME/Documents/emu/nds/NDS Bios & Firmware" [--jobs 6]
        [--frames 600] [--shots 30,115,240,360,600] [--press SPEC] [--no-ref]

Each ROM runs headless in our core (the sweep spawns itself with `--one`,
so a ROM that takes the core down takes only its own run) and in the
reference core with the same inputs. The default script is a generic "get
past the title": START@120, A@180, A@240, a touch at (128, 96)@300, START@360,
A@420, DOWN@450, A@480, B@540. Per ROM it records:

- **exceptions** (undefined instruction / abort, per CPU, with the last pc),
  **unmapped** accesses, a **hang** (ARM9 never halted for the last 120
  frames, pc inside 256 bytes, screens unchanged), **blank** screens (one
  colour at every shot), **power-off** (PM register 0 bit 6), audio peak
  and RMS around the mean (SOUNDBIAS DC removed), CPU ms per frame;
- the reference's shots at each checkpoint and two frames either side, its
  audio; a ROM with ARM9 code in the secure area is relocated for it
  (`ndsreloc`).

Statuses: **ok** every shot identical; **ok-phase** identical to a
reference frame at most two away; **differs** (largest share of a screen
that differs, raw and after the best phase offset); **broken** ours blank
where the reference is not, or crashed/hung with shots >= 25 % off;
**ref-broken** only the reference blank; **broken-ref-too** both.
`OUT/<rom>/side_<F>.png` shows ours beside the reference;
`OUT/results.tsv`, `OUT/table.md` the summary; `--report` rebuilds them
without running. `DINGBAT_NDS_HLE=1` in the environment runs our side with
the HLE BIOS (firmware still from `--bios`).

## The ROM set

60 homebrew binaries in `~/.cache/dingbat-nds/roms/homebrew/` (never in
git): 12 emulator ports, 11 3D programs (several on NitroFS), 9 2D games,
4 sound programs (trackers, a maxmod module player, a pxtone player), 7
tools, 17 demoscene productions from 2005 to 2026 (two written to break
emulators: Emulator Examination, "trans flag but it breaks all your
emulators"). Eras: 6 BlocksDS, 16 libnds 1.x, the rest unmarked (most with
the "Default (No interface)" DLDI stub; libfat programs therefore find no
card and say so, as on hardware without one). Plus devkitPro's
nds-examples built against our libnds 2 toolchain (72 ROMs,
`~/.cache/dingbat-nds/roms/homebrew-ex/`; nitrofs/libfat/dswifi examples
don't build without libfilesystem/libfat/dswifi). The table below lists
every homebrew title with its source, licence and SHA-1.

## Results in brief

Homebrew, 600 frames: 15 ok, 4 ok-phase, 26 differ, 8 run in ours where the
reference shows nothing (2048, the four libfat emulator ports after their
exit, DSMA's NitroFS example, pxtoneDS, UFO from Planet Slime), 7 broken in
both, **none broken in ours alone**. nds-examples: 36 ok / ok-phase, 35
differ (3D rasteriser edges, animation phase, touch raw values, the RTC),
1 broken in both (nehe lesson01: blank on both). A 1800-frame run of 20
games with a longer input script (menus, d-pad, touches) found no crash or
hang of ours that the reference doesn't share.

Almost every "differs" is one of:

- **phase**: animations and fades a few frames apart (talesofdagur,
  wolveslayer, breakingbad, lack of disco, skyjo, spaceimpakto, our first
  time, volumetricshadow, portalds, ...). Our CPU and card timing put
  loading and fades a few frames off the reference; with the HLE BIOS
  some of these match the reference exactly, so they are timing, not
  rendering;
- **power-off**: a program that exits powers the DS off; the reference goes
  black, our screens keep the last picture (peripherals' item, below);
- **3D**: edge pixels, and two timing cases (render-to-texture, dual-screen
  3D) listed for the 3D/display-timing owner;
- **random or host-dependent content**: TV-noise screens (NitroGrafx,
  S8DS), the RTC example, touch raw values (below).

## Fixes

Each in its own commit, and each core fix with a check in
`tests/nds_compat_test.nim` (`nimble test_ndscompat`).

1. **ARM9 protection unit aborts** (`a709685e`; `bus9.nim` pu_check9,
   `timing.nim` access tables, `arm/cpu.nim` take_abort). Found by
   nds-examples `exceptionTest`: a store to 0x2000 (no region under libnds)
   must reach libnds's data-abort handler and show its Guru Meditation
   screen; ours showed a blank screen and wrote into ITCM. Now a refused
   access aborts: background region and AP 0 grant nothing, AP 1/2/3/5/6
   as GBATEK "ARM CP15 Protection Unit"; data abort lr = opcode + 8, prefetch
   abort lr = opcode + 4 (the refused access does nothing; base write-back
   of the aborted opcode is not undone). An LDM/STM^ moving user-bank
   registers from a privileged mode stays privileged (SoulSilver does that
   over AP 1 RAM -- the first version aborted it). Cost +1.6 % host
   instructions on SoulSilver's boot: fetches are checked on branches and
   4 KB page crossings only, data accesses to main RAM and DTCM not at all
   (so a guard region inside main RAM does not abort), the last allowed page
   per fetch/read/write is remembered. exceptionTest now matches the
   reference's screen; gimlids (no BIOS files) takes the same data abort as
   the reference.
2. **Direct boot leaves the firmware's protection regions** (`8a2149fc`;
   `boot.nim`). The 4K intro sd4k enables the PU after defining only its
   ITCM region and runs from main RAM under the firmware's region 1; with
   the regions zeroed it sat in a prefetch-abort loop (with the old core it
   only worked because nothing aborted). Values read from the reference's
   direct boot by our `tests/nds/src/boot_cp15` ROM (docs/oracles.md, NDS
   core); control (12078h) and DTCM (0080000Ah) stay as the BIOS hand-off
   writes them. sd4k now renders its tunnel like the reference.
3. **CP15 writes no longer rebuild the tables needlessly** (`aa0f3ed4`;
   `timing.nim` update_control/update_regions, `bus9.nim` cp15_write). The
   BIOS's exception path switches the PU off and on around each pass; The
   Strongest Demo, crashed into an abort loop (white on both cores), did
   that thousands of times a frame and every control write recomputed 4096
   pages: 1235 ms of CPU per frame. A write that changes nothing is ignored,
   a control write flips the enables only, a real region change paints the
   main-RAM pages region by region. 300 frames: 36.6 s -> 1.9 s.
4. **ndsreloc shifted the FAT offset wrongly** (`c86d9df2`; tools only). The
   header's FAT offset (0x48) was left behind when the ARM9 binary moved, so
   every relocated NitroFS ROM read garbage files in the reference ("Failed
   to initialize filesystem" in PortalDS, "Not enough memory" in
   WolveSlayer, a struct overflow on Triple Triad). After the fix Traffic
   Escape matches frame for frame and the others line up.

5. **ARM9 branch refill for a jump back into the fetched word**
   (`a603bbf2`; `bus9.nim` fetch_cost9). The fetch-cost model inferred
   branches from word addresses, so a jump to the word just fetched (a
   two-opcode Thumb loop, ARM "B .") was free: WaitByLoop's SUB/BGT ran at
   2 ARM9 cycles a pass in the real BIOS where GBATEK's WaitByLoop table
   says 4 (20BAh*2 passes per ms at 67 MHz with the BIOS cached). Branches
   are now told from the exact opcode address. Programs spinning in such
   loops now execute a third as many opcodes (StellaDS after its exit:
   1106k -> 379k ARM9 opcodes a frame, 170 -> 79 M host instructions).
6. **HLE BIOS SWIs cost what the BIOS's code costs** (`81365e68`;
   `hle_bios.nim` hle_overhead). The Nim SWIs charged only their memory accesses: a
   512-unit CpuSet took a third of the real BIOS's cycles, GetCRC16 a
   fiftieth, Div/Sqrt almost nothing. Entry/return plus loop overhead,
   measured by running the BIOS dumps' own code in this core (ARM9 with PU
   and caches on) and fitted as base + per unit, now lands within 2 % from
   8 to 512 units. (Found because HLE and real-BIOS runs of the sweep
   disagreed on timing; allocation_test still runs a frame ahead under the
   HLE, so something else -- IRQ entry or the guest IntrWait code -- is
   also cheaper than the BIOS's.)

SoulSilver frames 3000/5000/8000 are unchanged by all of them, with the
real BIOS and with the HLE BIOS (e4b66d68.., 6cf51b7e.., d2ad8167..).
## Open items, by owner

**System peripherals (power):**
- Power-off (fixed on `nds-accuracy`, docs/nds/accuracy.md): after PM
  register 0 bit 6 (every libnds program that returns from main, every
  emulator port without an SD card, START in most examples) both CPUs stop
  and both screens go black, as in the reference. Re-swept: ColecoDS,
  NINTV-DS, SpeccySE, StellaDS (broken-ref-too/ref-broken -> ok), Kekatsu
  (differs -> ok); DLDI benchmark, DSMA stress test and Emulator Examination
  now match after their exit (their remaining differences are before it);
  0.4-2.9 ms of CPU a frame instead of ~18.
- Touchscreen Z1/Z2 (TSC channels 3/4) read 0, so libnds's pressure reads
  1.0 in `pxi`/`touch_test` (the reference reads about -1/4096); GBATEK
  gives the formula, not values; a pressed stylus needs Z1 > 0, Z2 > Z1.

**3D / display timing:**
- `rttexample` (render-to-texture): the two passes' clear colours come out
  swapped against the reference. Rendering now starts at line 214 with the
  registers read per line (GBATEK; `nds-accuracy`), which gives the same
  picture: the demo writes CLEAR_COLOR at line 192, before 214. The
  reference reads the registers at line 192, before the write
  (3d_render_timing, docs/nds/accuracy.md); a hardware run decides.
- Counter-Strike DS: on the current base the screens are right after the
  switch to one 3D screen (16.6 % left: texel rounding on walls); the
  switch itself lands one frame later than in the reference (CPU timing).
  nds-examples `dual_screen` is ok.
- 3D rasteriser edges in nds-examples 3D and gl2d programs (0.01-5 %), and
  frame-phase differences in 3D animation.

**Card / real boot:**
- nds-examples `eeprom`: the raw header re-read in main mode is an invalid
  KEY2 command; ours answers the KEY2 stream (GBATEK), so the two copies
  differ and it asks to reinsert the card; the reference answers zeros
  (docs/nds/accuracy.md).
- Firmware boot: 2 frames behind the reference; 0.7 of them is the
  reference's cheaper ARM7 main-RAM data (arm7_timing; ours follows
  GBATEK), the rest is not found (docs/nds/accuracy.md, boot.md).

**Hardware question (CPU):**
- ARMv5 opcodes with cond = 1111 that aren't BLX/PLD/etc.: ours raises
  undefined, the reference runs them as no-ops (k2 "numbering sucks", in a
  crash path on both). GBATEK: "Reserved ARMv3 and up". Needs a hardware
  run; left as is.

**Seen, not ours or not decidable:**
- Blank in both: nehe lesson01, uxnds, LMNTS (bad header CRC), MCMC, Defcon
  Zero, DS-NICCC (its ARM7 calls a veneer into shared WRAM at 030000CD that
  holds ARM code), The Strongest Demo, "trans flag" (cycle-exact beam race).
- Only the reference blank: 2048 (white: rejected), pxtoneDS, UFO from
  Planet Slime (ours plays it with music), DSMA NitroFS example.
- Touch raw values: ours derives them from the firmware's calibration
  points (GBATEK), the reference returns 16 x pixel (2048, 1536 at
  (128, 96)); both convert back to the same pixel.
- BitBox: three single-line palette steps at the bottom of the bottom screen
  land a line later in the reference (raster timing of its palette writes).
- HLE BIOS vs real BIOS (our side only): of the 60 homebrew ROMs 8 differ,
  all by timing (fades/animation a frame or two apart; with the HLE BIOS
  talesofdagur matches the reference exactly where the real BIOS run
  doesn't); of the 72 examples, before their first input, only
  allocation_test (a frame ahead under the HLE) and RealTimeClock (the
  clock). No HLE-specific breakage.

## Performance outliers

Host instructions per emulated frame (`/usr/bin/time -l`, load-independent;
600 frames, the default input script, `--rtc 2004-01-01`, real BIOS; final
build):

| ROM | host M instr / frame | ARM9 k opcodes / frame | ARM7 k / frame | why |
|---|---|---|---|---|
| SoulSilver (boot) | 78.3 | 88 | 83 | baseline |
| trans flag (beam race) | 250 | 789 | 280 | never halts: cycle-counted waits on VCOUNT on both CPUs |
| UFO from Planet Slime | 215 | 517 | 245 | both CPUs poll instead of halting |
| sd4k | 155 | 244 | 0 | 3D: full-screen fogged tunnel (render.nim plot + fog ~60 % of samples) |
| k2 numbering sucks | 152 | 373 | 296 | polling, then its crash path |
| NitroGrafx | 151 | 516 | 8 | menu loop polls (3+ opcode loop) instead of halting |
| Our First Time | 141 | 366 | 2 | 3D + polling |
| MAXMXDS | 138 | 552 | 15 | polling |
| dsma_stress_test | 88 | 312 | 2 | spins after power-off (was 162) |
| StellaDS (and the no-SD ports) | 79 | 379 | 2 | spins after power-off (was 170) |
| The Strongest Demo | 51 | 150 | 7 | its abort loop; 1235 ms of CPU a frame before fix 3 |
| the big holstein | 26 | 80 | 1 | was 155: a two-opcode wait loop (fix 5) |
| hbmenu | 9.9 | 6 | 2 | halts between frames |

The remaining outliers never halt the ARM9 (and the beam-racing demos not
the ARM7 either): they busy-wait on VCOUNT or flags and execute 3-9x
SoulSilver's opcodes. At ~150-250 host instructions per emulated opcode
(macOS `sample` on a spinning ARM9: ~70 % in the inlined ArmCpu.run/step
with the fetch timing and cache-tag model, ~20 % in execute_arm; on
SoulSilver: run 40 %, read7 9 %, 2D composite 8 %, I-cache tag lookups
5 %) that is 2-3x SoulSilver's per-frame cost. sd4k is the one 3D-bound
case. Modelling power-off would remove the spinning ports' remaining cost;
the rest needs a cheaper interpreter path, not a per-ROM fix.
Since then (docs/nds/perf.md) idle-loop skipping removes most of a
spinning program's cost when its loop provably changes nothing (`B .`
endings, VCOUNT and IPC polls: 13x fewer host instructions on fb_both,
-31 % on trans flag), and an unchanged 3D frame is reused; the figures
above are from before.

## Tables

Sweep outputs: homebrew at 600 frames (`sw2`), nds-examples with an input script that avoids START (`A@120, TOUCH:128:96@200+10, RIGHT@260+30, UP@300+30, B@360, L@400, R@420, A@480`), and 20 games at 1800 frames with a longer script (menus, d-pad, touches). "aligned" is the worst shot after the best offset of up to two frames (reference frame minus ours).

### Catalogue

| ROM | Title | Kind | Needs | Licence | Source | SHA-1 |
|---|---|---|---|---|---|---|
| 2048 | 2048 DS 1.0.2 | 2D game | none | MIT | https://github.com/mdmrk/2048-nds/releases/download/v1.0.2/2048-nds.nds | `40106deb0ee58e2ecbe10f8fcf9311575cafef69` |
| a8ds | A8DS 4.2 (Atari 800/XL) | emulator port | SD: roms | GPL-2.0 | https://github.com/wavemotion-dave/A8DS/releases/download/4.2/A8DS.nds | `b4c4abe522d404a6664fd83bece8f84f257b9395` |
| blimpchicken | Blimp Chicken DS | 3D | none | CC0-1.0 | https://github.com/My-name-is-TJ/blimp-chicken-ds/releases/download/NdsFile/BlimpChicken.nds | `7295bdfd95abe35d424cd0c7120dc78fa527a516` |
| breakingbad | Breaking Bad DS 1.0.6 | 2D game | NitroFS | Apache-2.0 | https://github.com/WiIIiam278/breaking-bad-ds/releases/download/1.0.6/breaking-bad-ds.nds | `7dce261da5d23cf01ce64883f8df7265b8a7b229` |
| bunjalloo | Bunjalloo 0.12.0 | tool | WiFi; SD: config | GPL-3.0 | https://codeberg.org/SkyLyrac/bunjalloo/releases/download/v0.12.0/bunjalloo_v0.12.0.zip | `df40a3f0ec2745a5707e7d51bbde23e4dc21cd70` |
| cavestoryds | Cave Story DS 0.4 (EN) | 2D game | none | MIT (mods) + freeware Cave Story data | https://github.com/tilderain/CaveStoryNDS/releases/download/0.4/CaveStoryDS-0.4.7z | `da25d96714ce08085cdedaac2e189ca7ee446ccd` |
| colecods | ColecoDS 11.0 (ColecoVision/MSX/etc) | emulator port | SD: BIOS+roms | non-commercial freeware (README) | https://github.com/wavemotion-dave/ColecoDS/releases/download/11.0/ColecoDS.nds | `60c13b6cc87707c04e117b06f636eef7a1ee618c` |
| counterstrike | Counter-Strike DS 1.0.0 | 3D | SD: soundbank.bin + music (optional) | no licence stated | https://github.com/Fewnity/Counter-Strike-Nintendo-DS/releases/download/1.0.0/Counter.Strike.DS.1.0.0.zip | `752f5d6a245aa94f42b1a188e716ad57d24aafa4` |
| delusion | d-Elusion 0.3 | 2D game | none | no licence stated | https://github.com/NotImplementedLife/d-Elusion/releases/download/0.3/d-Elusion.nds | `97b871cf5c218b5d86a01e23db3b34f981b49ed8` |
| dldibench | DLDI driver benchmark 0.4.3 | tool | SD (DLDI) | MIT | https://github.com/asiekierka/dldi-driver-benchmark/releases/download/v0.4.3/dldi_benchmark_blocksds.nds | `3a04bcf9755c0e5f1ab22f71a5237249687c2058` |
| ds81 | DS81 1.3a (ZX81) | emulator port | none | GPL-2.0 | https://github.com/asiekierka/DS81/releases/download/v1.3a/DS81-V1.3a.zip | `348fa6f089534e9eead202a17dc40769088269a0` |
| dscraft | DS-Craft beta 1.7.1 | 3D | NitroFS | MIT | https://github.com/moltony/ds-craft/releases/download/beta1.7.1/ds-craft-beta1.7.1.nds | `7f34bc5e2ecd8b85e191d23352816ba5cd06d915` |
| dsma_nitrofs | DSMA example: filesystem_loading | 3D | NitroFS | CC0-1.0 (examples) | https://codeberg.org/SkyLyrac/dsma-library/releases/download/v0.2.0/dsma-examples-v0.2.0.zip | `542526287ed3095b1dea7ca076c43d6f7226c563` |
| dsma_stress_test | DSMA example: stress_test | 3D | none | CC0-1.0 (examples) | https://codeberg.org/SkyLyrac/dsma-library/releases/download/v0.2.0/dsma-examples-v0.2.0.zip | `0ebd39a8a6cd44fe45f769b50b698b9b76498043` |
| eigenmathds | Eigenmath DS 1.1 | tool | none | GPL-3.0 | https://github.com/AntonioND/eigenmathds/releases/download/v1.1/eigenmathds.nds | `256e0f5b46a318e13e744c2b161986e3fa749a56` |
| gameyob | GameYob 0.5.2 (GB/GBC) | emulator port | SD: roms | MIT | https://github.com/Stewmath/GameYob/releases/download/v0.5.2/gameyob.zip | `ab8fd2aa79d2ef1a688282530e9eb0a493d77d8a` |
| gimlids | GimliDS 1.7 (C64) | emulator port | SD: BIOS+roms | GPL-2.0 (Frodo, README) | https://github.com/wavemotion-dave/GimliDS/releases/download/1.7/GimliDS.nds | `af5de47c079711fdbc16ffc80652e828ac534e1b` |
| hbmenu090 | devkitPro Homebrew Menu 0.9.0 | tool | SD: .nds files | GPL-2.0+ (license.txt) | https://github.com/devkitPro/nds-hb-menu/releases/download/v0.9.0/hbmenu-0.9.0.zip | `1a13b537968a11fe4210c26131bbeebff82161cb` |
| kekatsu | Kekatsu 1.2.0 | tool | SD: config + WiFi | MIT | https://github.com/cavv-dev/Kekatsu-DS/releases/download/v1.2.0/Kekatsu.nds | `3e840c319aeffeb8ef7e77e12372419ab3ebe3f4` |
| maxmxds | MAXMXDS 1.0 | sound | SD: modules | MIT (README) | https://github.com/merumerutho/MAXMXDS/releases/download/v1.0/MAXMXDS.nds | `a2de74380815fd79e23428ce2cad7932fde4c005` |
| nesds | nesDS 2.1 (NES) | emulator port | SD: roms | public domain (README) | https://github.com/DS-Homebrew/NesDS/releases/download/v2.1/nesDS.nds | `1728ec1d27f838e6db35f8f051371b55fefd6339` |
| nintvds | NINTV-DS 6.3 (Intellivision) | emulator port | SD: BIOS+roms | non-commercial freeware (README) | https://github.com/wavemotion-dave/NINTV-DS/releases/download/6.3/NINTV-DS.nds | `6eb5ae6f630318f5b29211e00496bdbfc81bf9a5` |
| nitrografx | NitroGrafx 0.9.0 (PC Engine) | emulator port | SD: roms | no licence stated | https://github.com/FluBBaOfWard/NitroGrafx/releases/download/v0.9.0/NitroGrafx0_9_0.zip | `452004a9f767eecc718a8afe097343589c717e41` |
| nitrotracker03 | NitroTracker 0.3 (2006) | sound | SD: songs (optional) | GPL (README) | https://files.scene.org/view/resources/music/trackers/nitrotracker.zip | `1d4b40a98f0c321aa553e7b56f67f784585e8b63` |
| nitroustracker | NitrousTracker 0.7.0b2 | sound | SD: songs (optional) | GPL-3.0 | https://github.com/NitrousTracker/nitroustracker/releases/download/release/0.7.0b2/NitrousTracker-0.7.0b2-nds.zip | `a6ef8bd1a5d81bc7eecd76a42ce7077dfbf41066` |
| portalds | PortalDS r4 | 3D | NitroFS | no licence stated | https://github.com/Kuratius/portalDS/releases/download/r4/portalDS.nds | `6b8f2c8b93d76c6004d1b25681512d3b9ff71f45` |
| pxtoneds | pxtoneDS sample2 (NitroFS) | sound | NitroFS | no licence stated | https://github.com/tilderain/pxtoneDS/releases/download/sample2/pxtoneDS-nitro.nds | `5661ece06f5200f033317a64aa220c9627ffdd3e` |
| rocketvideo | Rocket Video Player 2.3.0 | tool | SD: .rvid videos | MIT | https://github.com/RocketRobz/RocketVideoPlayer/releases/download/v2.3.0/RocketVideoPlayer.nds | `3492ab79bc755244d2bd10423961798baf36a7cb` |
| rttexample | Render-to-texture example | 3D | none | no licence stated | https://github.com/AntonioND/nds-rtt-example/releases/download/v1.0/nds-rtt-example.nds | `b3c6196dd499947a1eed3421962854518cec160d` |
| s8ds | S8DS 1.1.8 (Sega 8-bit) | emulator port | SD: roms | no licence stated | https://github.com/FluBBaOfWard/S8DS/releases/download/v1.1.8/S8DS.zip | `1ddfd158946f6b9fbd85cd6930ec0e5038cef4c3` |
| scene_beamrace_transflag | trans flag but it breaks all your emulators (PoroCYon) | demoscene | none | scene release (free download) | https://files.scene.org/view/demos/artists/porocyon/beamrace.nds | `db5e40ec711505357d54acfdc476dac2c63a0885` |
| scene_big_holstein | the big holstein (k2) | demoscene | none | scene release (free download) | https://ftp.untergrund.net/users/yago/nds/the_big_holstein_k2.nds | `90c164e1be4c030b32e3b87d781c489679209601` |
| scene_bitbox | BitBox (MsK`, Nurykabe, hitchhikr) 4k, safe build | demoscene | none | scene release (free download) | https://lywenn.eu.org/files/bitbox.zip | `f3c9dbec62ae09160dd00352815daa6a46a9efd2` |
| scene_defcon_zero | Defcon Zero (Scarab) | demoscene | none | scene release (free download) | http://www.computer-classics.de/_extdata/defcon-zero.zip | `ec39f03968660b49c1ad793560804d2c256b536d` |
| scene_dicewars | Dicewars DS (melw & reko) | demoscene | none | scene release (free download) | https://files.scene.org/view/parties/2007/assembly07/game/dicewars_by_melw_reko__1in10.zip | `20f343b041ad792eab204a1106528994d137e530` |
| scene_dsniccc | 2019: A DS-NICCC Odyssey (k2 & Titan) | demoscene | none | scene release (free download) | https://files.scene.org/view/parties/2019/nordlicht19/wild/k2_ttn-dsniccc.zip | `df275f4ab4178bc18b1a8de89f0faa1fc5d0b5a9` |
| scene_emulator_examination | Emulator Examination (Stargaze, Revision 2026) | demoscene | none | scene release (free download) | https://files.scene.org/view/parties/2026/revision26/wild/sgz_rvn26_ee_final.zip | `6bd29f4885352c211d5a662ac1155a3c391a2cae` |
| scene_jumalauta_xmas05 | Jumalauta NDS Christmas 2005 Demo | demoscene | none | scene release (free download) | https://files.scene.org/view/demos/groups/jumalauta/jml-jl05.zip | `142314432844646407a4e5e1d3015bc37159dcfd` |
| scene_k2_numbering_sucks | k2 - 029: numbering sucks | demoscene | none | scene release (free download) | https://ftp.untergrund.net/users/yago/nds/K2_-_numbering_sucks.zip | `0748c4db5269a6f521970897b11d4152a82cbee5` |
| scene_lack_of_disco | Lack Of Disco (Popsy Team) | demoscene | none | scene release (free download) | https://files.scene.org/view/parties/2009/main09/wild/lack.of.disco.nds-popsy.team.zip | `c74ec05cadbb9bb4ee8c9a936ca77a1a5f5d78c1` |
| scene_lmnts | LMNTS (Titan) phat | demoscene | none | scene release (free download) | https://ftp.untergrund.net/users/irokos/titan/titan-NDSlmnts.zip | `f2c69ecd6953ecd7f828bc94cd7c0178f2b99629` |
| scene_mcmc | MCMC (The Royal Elite Ninjas) | demoscene | none | scene release (free download) | https://files.scene.org/view/parties/2013/assembly13/real_wild/mcmc_by_elite_ninjas_inc.zip | `c5cd9fc170179227eb41f874dc33e072155fd75f` |
| scene_mods_vol1 | MoDS Volume 1 (Resistance & Desire) | demoscene | none | scene release (free download) | https://files.scene.org/view/parties/2014/solskogen14/wild/mods_vol1.zip | `8dde58f9ef992cd4644637a30cfb102aefdec413` |
| scene_our_first_time | Our First Time (Elektro Dude, Dr. Bitsch, Mr. M) | demoscene | none | scene release (free download) | https://ftp.untergrund.net/users/breakpoint/2007/RealWild/ndsdemo.nds | `3961bca848d2e4c2e819480ce1fbd303f8f5672d` |
| scene_sd4k | sd-4k (Speckdrumm) | demoscene | none | scene release (free download) | https://files.scene.org/view/demos/groups/speckdrumm/sd_sd-4k.zip | `1bd5264f39e925b05e4c949d70ab7fe148647028` |
| scene_strongest_demo | The Strongest Demo (SVatG) | demoscene | none | scene release (free download) | http://wakaba.c3.cx/releases/scene/the_strongest_demo.zip | `04fc2470d460fb6af744bc2e64fe175da3a8bc3a` |
| scene_ups | UFO from Planet Slime (k2, Peisik, SVatG) | demoscene | none | scene release (free download) | https://files.scene.org/view/parties/2020/revision20/wild/k2%2Bpsk%2Bsvatg-ups.zip | `0699953ef3bbd44f784fd80fa732c0a8d8d468d9` |
| skyjo | Skyjo DS 2.0 | 2D game | NitroFS | Apache-2.0 | https://github.com/Warioware64/Skyjo-DS/releases/download/v2.0/skyjo-nds.nds | `ff8d578fa94e327463b52e5c52194260eb2c273e` |
| spaceimpakto | Space Impakto DS | 2D game | none | MIT | https://codeberg.org/SkyLyrac/SpaceImpakto-DS/releases/download/v20250829/SpaceImpakto-DS-v20250829.zip | `e4bd477b8c7d5b85643db181b4bf508a61686024` |
| speccyse | SpeccySE 2.1a (ZX Spectrum) | emulator port | SD: BIOS+roms | non-commercial freeware (README) | https://github.com/wavemotion-dave/SpeccySE/releases/download/2.1a/SpeccySE.nds | `3f746384fb49dc5a43c6e2852d9380a6d9a091a6` |
| spelunkyds | Spelunky DS 1.13 | 2D game | none | GPL (code) + Spelunky User License (assets) | https://github.com/dbeef/spelunky-ds/releases/download/1.13DSi%2B%2B/spelunkyds.nds | `1e22c8ff330915d1777851d0ed53717fa20ab1ad` |
| stellads | StellaDS 8.4a (Atari 2600) | emulator port | SD: roms | GPL-2.0 | https://github.com/wavemotion-dave/StellaDS/releases/download/8.4a/StellaDS.nds | `538e4a2d5722f09827a17f7f912bb262e4ccf9cf` |
| talesofdagur | Tales of Dagur | 2D game | NitroFS | WTFPL | https://codeberg.org/SkyLyrac/talesofdagur/releases/download/v20250325/talesofdagur.nds | `df4d38f9faf11b739018568a1096f6e5151f9fa6` |
| tetris3d | Tetris 3DS 1.4 | 3D | none | GPL-3.0 | https://codeberg.org/SkyLyrac/tetris-3ds/releases/download/v1.4/Tetris_3DS_v1.4.zip | `6f2b47bdc27377b5074a8a07082ea1b0cdea2b38` |
| trafficescape | Traffic Escape DS 1.2 | 3D | NitroFS | Apache-2.0 | https://github.com/Warioware64/Traffic-Escape-DS/releases/download/v1.2/Traffic_Escape_DS.nds | `7e02c84f71cfaee5048d5a01614564f6f670f71e` |
| tripletriad | Triple Triad DS | 2D game | NitroFS | no licence stated | https://codeberg.org/SkyLyrac/triple-triad-ds/releases/download/v20250112/triple-triad-ds_v20250112.zip | `9981c26f09259519c358c4b72be1bac670770731` |
| uxnds | uxnds 0.5.3 (uxn/Varvara VM) | emulator port | SD: roms | MIT | https://github.com/asiekierka/uxnds/releases/download/v0.5.3/uxnds053.zip | `7dcda8e4b6cb43d508f3e8a867e0103fc657555d` |
| vnds | VNDS 1.4.14-pre | tool | SD: /vnds novels | GPL-2.0 | https://github.com/asiekierka/vnds/releases/download/1.4.14-pre/vnds-1.4.14-pre.zip | `c566071f38146544e196d45381bb6a9f91048d07` |
| volumetricshadow | Volumetric Shadow Demo 1.7.2 | 3D | NitroFS | no licence stated | https://codeberg.org/SkyLyrac/volumetric_shadow_demo/releases/download/v1.7.2/volumetric_shadow_demo.nds | `4142fb30da19beff3377005af73caf56d7c6b480` |
| wolveslayer | WolveSlayer (BlocksDS port) | 3D | NitroFS | MIT | https://github.com/AntonioND/wolveslayer/releases/download/v20240731/wolveslayer.nds | `8ab8b0bed86a8fdc1e99f9bfcf099d848d5c5ce0` |

### Homebrew results (600 frames)

| ROM | status | diff % | aligned % (offset) | ours | reference | audio RMS ours / ref | triage |
|---|---|---|---|---|---|---|---|
| 2048 | ref-broken | 100.00 | 100.00 | - | blank silent | 0.002 / 0.000 | the reference shows a white frame (rejects the ROM); ours runs the game |
| a8ds | ok | 0.00 | 0.00 | top-blank silent | silent | 0.000 / 0.000 |  |
| blimpchicken | differs | 7.36 | 7.36 (+1) | - | - | 0.097 / 0.093 | a frame out of phase, then 3D edge pixels |
| breakingbad | ok | 0.00 | 0.00 | top-blank silent unmapped:1 | silent | 0.000 / 0.000 | same picture at 600 frames; in the long run its fades run a few frames behind |
| bunjalloo | ok | 0.00 | 0.00 | bottom-blank silent | silent | 0.000 / 0.000 |  |
| cavestoryds | differs | 0.34 | 0.34 | bottom-blank | - | 0.035 / 0.033 | the frame-30 shot only (start-up a frame apart); intro and dialogue identical |
| colecods | ref-broken | 100.00 | 100.00 | power-off top-blank silent | blank silent | 0.000 / 0.000 | "Unable to initialize libfat" (no SD card), exits: the reference powers off to black, ours keeps the last picture |
| counterstrike | differs | 99.66 | 99.66 | silent | silent | 0.000 / 0.000 | dual-screen 3D (capture + LCD swap each frame); the swapping stops at frame ~27 and our last capture leaves the top view in the bottom bank, the reference keeps the gamepad screen there (3D/capture timing) |
| delusion | ok-phase | 0.07 | 0.00 (-2) | - | - | 0.002 / 0.001 |  |
| dldibench | differs | 12.45 | 12.45 | power-off silent | silent | 0.000 / 0.000 | same menu ("Default (No interface)" DLDI), exits at START (power-off) |
| ds81 | differs | 50.01 | 50.01 (-1) | silent | silent | 0.000 / 0.000 | one shot: the keyboard's blink a frame apart |
| dscraft | ok-phase | 100.00 | 0.00 (-2) | silent | silent | 0.000 / 0.000 |  |
| dsma_nitrofs | ref-broken | 10.42 | 10.42 | power-off silent | blank silent | 0.000 / 0.000 | the reference stays black; ours loads the NitroFS model and animates it |
| dsma_stress_test | differs | 100.00 | 100.00 (-2,+1) | power-off silent | silent | 0.000 / 0.000 | same until START exits (power-off); before that a frame out of phase |
| eigenmathds | ok | 0.00 | 0.00 | silent | silent | 0.000 / 0.000 |  |
| gameyob | ok | 0.00 | 0.00 | - | - | 0.060 / 0.014 |  |
| gimlids | differs | 15.99 | 15.99 | exc9@020524B8 hang@020348F6 | - | 0.028 / 0.026 | no BIOS files on SD: both take the same data abort into libnds's exception screen; register values differ |
| hbmenu090 | ok | 0.00 | 0.00 | silent | silent | 0.000 / 0.000 |  |
| kekatsu | differs | 100.00 | 100.00 | power-off top-blank silent | silent | 0.000 / 0.000 | same menu, exits at START (power-off) |
| maxmxds | ok | 0.00 | 0.00 | silent | silent | 0.000 / 0.000 |  |
| nesds | ok | 0.00 | 0.00 | top-blank silent unmapped:1 | silent | 0.000 / 0.000 |  |
| nintvds | ref-broken | 100.00 | 100.00 | power-off top-blank silent | blank silent | 0.000 / 0.000 | as ColecoDS (no SD card, exits) |
| nitrografx | differs | 50.17 | 49.83 (+1,+2,-2) | silent | silent | 0.000 / 0.000 | TV-noise screen (random) on top; menus identical |
| nitrotracker03 | differs | 1.12 | 1.12 | silent | silent | 0.000 / 0.000 | one shot, a cursor blink |
| nitroustracker | ok | 0.00 | 0.00 | silent | silent | 0.000 / 0.000 |  |
| portalds | differs | 7.09 | 7.01 (-1) | silent | silent | 0.000 / 0.000 | animated 3D title a frame or two apart |
| pxtoneds | ref-broken | 100.00 | 100.00 | silent | blank silent | 0.000 / 0.000 | the reference turns white at frame ~100; ours shows the player's icon (both silent without input) |
| rocketvideo | ok | 0.00 | 0.00 | top-blank silent unmapped:1 | silent | 0.000 / 0.000 |  |
| rttexample | differs | 96.34 | 96.34 (-2) | silent | silent | 0.000 / 0.000 | render-to-texture: the two passes' clear colours come out swapped (our 3D frame renders at line 0 with the registers then; GBATEK: rendering starts 48 lines ahead with live registers) - 3D timing |
| s8ds | differs | 49.76 | 49.57 (+2) | silent unmapped:256 | silent | 0.000 / 0.000 | TV-noise screen (random) on top; menus identical |
| scene_beamrace_transflag | broken-ref-too | 100.00 | 100.00 | hang@0200A048 blank silent | blank silent | 0.000 / 0.000 | cycle-exact beam race ("breaks all your emulators"): blank in both |
| scene_big_holstein | ok | 0.00 | 0.00 | top-blank silent | silent | 0.000 / 0.000 |  |
| scene_bitbox | differs | 36.93 | 49.44 (-1) | - | - | 0.174 / 0.167 | raster gradient a frame apart at first; later 2-3 % of the bottom: three single-line palette steps where the reference changes a line later |
| scene_defcon_zero | broken-ref-too | 0.00 | 0.00 | hang@027FFE78 blank static silent | blank silent | 0.000 / 0.000 | blank in both; ours spins in main RAM at 027FFE78 |
| scene_dicewars | ok | 0.00 | 0.00 | exc7@080000C0 hang@027FFE04 | - | 0.002 / 0.002 | same pictures; after quitting both jump into the empty GBA slot (ours: ARM7 undefined-instruction loop at 080000C0) |
| scene_dsniccc | broken-ref-too | 0.00 | 0.00 | exc7@037FA5E2 blank static silent | blank silent | 0.000 / 0.000 | blank in both: the ARM7 calls a veneer into shared WRAM (030000CD) that holds ARM code, runs into data, undefined-instruction loop |
| scene_emulator_examination | differs | 87.37 | 87.37 (+1) | power-off | - | 0.042 / 0.093 | both show the demo's "this needs a DSi" screen, then it exits (power-off) |
| scene_jumalauta_xmas05 | ok | 0.00 | 0.00 | - | - | 0.164 / 0.161 |  |
| scene_k2_numbering_sucks | differs | 0.15 | 0.15 | exc9@02017128 hang@020226BA top-blank silent | silent | 0.000 / 0.000 | both crash: a null vtable entry calls address 0 and returns into Thumb code as ARM; our exception screen shows pc 02017128, the reference's 0201713C because it runs cond=NV (1111) opcodes as no-ops where we raise undefined (GBATEK: reserved) |
| scene_lack_of_disco | differs | 51.43 | 51.40 (+2,-2) | - | - | 0.123 / 0.118 | fades a frame or two apart |
| scene_lmnts | broken-ref-too | 0.00 | 0.00 | blank | blank | 0.214 / 0.212 | blank in both (bad header CRC); same audio |
| scene_mcmc | broken-ref-too | 0.00 | 0.00 | blank unmapped:2 | blank silent | 0.052 / 0.000 | blank in both; ours plays audio, the reference is silent |
| scene_mods_vol1 | ok-phase | 4.74 | 0.00 (-1) | unmapped:2 | - | 0.036 / 0.034 |  |
| scene_our_first_time | differs | 60.80 | 60.80 | bottom-blank | - | 0.053 / 0.053 | 3D animation a few frames behind |
| scene_sd4k | differs | 16.44 | 16.44 | bottom-blank silent | silent | 0.000 / 0.000 | fixed (direct-boot PU regions); the rest is the tunnel's animation phase |
| scene_strongest_demo | broken-ref-too | 0.00 | 0.00 | exc9@00000000 blank static silent | blank silent | 0.000 / 0.000 | white in both; ours loops through the BIOS abort path (was 1.2 s/frame, fixed) |
| scene_ups | ref-broken | 100.00 | 100.00 | - | blank silent | 0.147 / 0.000 | the reference stays white after START; ours runs the demo with music |
| skyjo | differs | 66.96 | 66.96 (-2) | - | - | 0.041 / 0.041 | animated background a few frames apart |
| spaceimpakto | differs | 82.66 | 82.66 (+1) | - | - | 0.020 / 0.020 | plasma animation phase |
| speccyse | ref-broken | 100.00 | 100.00 | power-off top-blank silent | blank silent | 0.000 / 0.000 | as ColecoDS (no SD card, exits) |
| spelunkyds | ok-phase | 0.16 | 0.00 (-1) | unmapped:16576 | - | 0.090 / 0.089 | 16576 null-pointer reads (0-3E), harmless on both |
| stellads | ref-broken | 100.00 | 100.00 | power-off top-blank silent | blank silent | 0.000 / 0.000 | as ColecoDS (no SD card, exits) |
| talesofdagur | differs | 95.88 | 94.84 (+2,-2,-1) | - | - | 0.140 / 0.133 | fades a few frames apart (the HLE BIOS run matches the reference exactly at 115/240) |
| tetris3d | differs | 1.10 | 1.10 | silent | silent | 0.000 / 0.000 | 1 % (a frame of falling-piece phase) |
| trafficescape | ok | 0.00 | 0.00 | - | - | 0.063 / 0.063 |  |
| tripletriad | differs | 4.32 | 2.29 (-2) | unmapped:48588 | - | 0.039 / 0.039 | a moving sprite a frame apart; 48588 reads of addresses 0-3E (a null struct pointer; ok on both) |
| uxnds | broken-ref-too | 0.00 | 0.00 | blank silent | blank silent | 0.000 / 0.000 | blank in both (needs ROMs on SD) |
| vnds | ok | 0.00 | 0.00 | bottom-blank silent | silent | 0.000 / 0.000 |  |
| volumetricshadow | differs | 98.46 | 98.45 (-2) | silent | silent | 0.000 / 0.000 | animated character a frame apart (vertex/polygon counters show the same phase lag) |
| wolveslayer | differs | 100.00 | 99.59 (-2) | - | - | 0.425 / 0.414 | intro fade a few frames behind; in the long run the inputs land in a different game state |

### Long run (1800 frames, game subset)

| ROM | status | diff % | aligned % (offset) | ours | reference |
|---|---|---|---|---|---|
| 2048 | ref-broken | 100.00 | 100.00 | - | blank silent |
| blimpchicken | differs | 4.47 | 4.47 (+1) | - | - |
| breakingbad | differs | 35.68 | 34.77 (+2) | unmapped:1 | - |
| cavestoryds | differs | 0.15 | 0.15 (-1,-2) | bottom-blank | - |
| counterstrike | differs | 99.66 | 99.66 | silent | silent |
| delusion | ok | 0.00 | 0.00 | unmapped:22528 | - |
| dscraft | ok | 0.00 | 0.00 | silent | silent |
| eigenmathds | ok | 0.00 | 0.00 | silent | silent |
| maxmxds | ok | 0.00 | 0.00 | silent | silent |
| nitroustracker | differs | 1.04 | 0.03 (+1) | silent | silent |
| portalds | differs | 7.04 | 6.99 (-2) | silent | silent |
| scene_dicewars | ok | 0.00 | 0.00 | exc7@080000C0 hang@027FFE04 | - |
| skyjo | differs | 66.96 | 66.96 (-2) | - | - |
| spaceimpakto | differs | 82.66 | 54.27 (+2,-1) | - | - |
| spelunkyds | ok | 0.00 | 0.00 | unmapped:18112 | - |
| talesofdagur | differs | 87.30 | 87.10 (+2,+1) | unmapped:1168 | - |
| tetris3d | differs | 73.52 | 2.12 (+2) | silent | silent |
| trafficescape | ok | 0.00 | 0.00 | - | - |
| tripletriad | differs | 7.33 | 7.33 | hang@02021C5A unmapped:48588 | - |
| wolveslayer | differs | 91.07 | 91.06 (-2) | - | - |

### nds-examples (72, 600 frames)

ok / ok-phase (36): 16bit_color_bmp, 256_color_bmp, 256colorTilemap, Double_Buffer, addon, all_in_one, allocation_test, animate_simple, ansi_console, arm9, audio_modes, backgrounds, basic_sound, bitmap_sprites, console_windows, custom_font, exceptionTest, fire_and_sprites, fonts, hello_world, keyboard_async, keyboard_stdin, lesson09, micrecord, primitives, reverb, rotation, rotscale_text, scrolling, simple, song_events_example, song_events_example2, sprite_extended_palettes, sprite_rotate, timercallback, windows

| ROM | status | diff % | aligned % (offset) | ours | reference |
|---|---|---|---|---|---|
| 2Dplus3D | differs | 4.03 | 4.03 | silent | silent |
| 3D_Both_Screens | differs | 0.63 | 0.63 | silent | silent |
| BoxTest | differs | 0.34 | 0.34 (-1,+2,-2) | silent | silent |
| Display_List | differs | 0.01 | 0.01 | bottom-blank silent | silent |
| Display_List_2 | differs | 3.82 | 3.82 | bottom-blank silent | silent |
| Env_Mapping | differs | 5.48 | 5.48 | bottom-blank silent | silent |
| Mixed_Text_3D | differs | 0.04 | 0.04 | bottom-blank silent | silent |
| Ortho | differs | 0.38 | 0.38 | bottom-blank silent | silent |
| Paletted_Cube | differs | 1.38 | 1.38 | silent | silent |
| Picking | differs | 0.11 | 0.11 | top-blank silent | silent |
| RealTimeClock | differs | 6.22 | 6.22 | silent | silent |
| Simple_Quad | differs | 0.10 | 0.10 | bottom-blank silent | silent |
| Simple_Tri | differs | 0.01 | 0.01 | bottom-blank silent | silent |
| Textured_Cube | differs | 21.57 | 21.57 | bottom-blank silent | silent |
| Textured_Quad | differs | 0.19 | 0.19 | bottom-blank silent | silent |
| Toon_Shading | differs | 0.70 | 0.70 | bottom-blank silent | silent |
| combined | differs | 0.14 | 0.14 | top-blank silent | silent |
| dual_screen | differs | 28.93 | 28.88 (-2,+2) | silent | silent |
| eeprom | differs | 0.84 | 0.84 | top-blank silent | silent |
| lesson01 | broken-ref-too | 0.00 | 0.00 | blank silent | blank silent |
| lesson02 | differs | 0.00 | 0.00 | bottom-blank silent | silent |
| lesson03 | differs | 0.00 | 0.00 | bottom-blank silent | silent |
| lesson04 | differs | 0.04 | 0.04 | bottom-blank silent | silent |
| lesson05 | differs | 0.62 | 0.62 | bottom-blank silent | silent |
| lesson06 | differs | 0.38 | 0.38 | bottom-blank silent | silent |
| lesson07 | differs | 3.25 | 3.25 (+1) | bottom-blank silent | silent |
| lesson08 | differs | 3.40 | 3.40 (+1) | bottom-blank silent | silent |
| lesson10 | differs | 13.99 | 13.53 (-1) | bottom-blank silent | silent |
| lesson10b | differs | 13.35 | 13.35 | bottom-blank silent | silent |
| lesson11 | differs | 2.31 | 2.31 | bottom-blank silent | silent |
| pxi | differs | 0.44 | 0.44 | top-blank silent | silent |
| sprites | differs | 60.87 | 10.56 (-1) | bottom-blank silent | silent |
| stopwatch | differs | 0.22 | 0.12 (+1,-2) | top-blank silent | silent |
| streaming | differs | 0.52 | 0.52 | top-blank | - |
| touch_look | differs | 9.00 | 9.00 | bottom-blank silent | silent |
| touch_test | differs | 0.28 | 0.28 | top-blank silent | silent |
