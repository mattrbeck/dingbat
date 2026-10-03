# Commercial games: Golden Sun: Dark Dawn, Pokemon Mystery Dungeon, SoulSilver

Round 8 on branch `nds-commercial` (2026-10-02/03). Two commercial games
that had never run on the DS core were driven from power-on into play by
`ndsrun --press` scripts and compared, scene by scene, with the reference
core (`tools/ndsref --depth5`, the core and its settings in docs/oracles.md); SoulSilver
went past the p12 script. The user's own dumps are read at run time only
(`~/.cache/dingbat-nds/*.nds`, BIOS/firmware from `~/Documents/emu/nds/NDS
Bios & Firmware`); no game byte is in the repository.

Results in one line each:

| Game | Reaches | Picture vs the reference | Sound | BIOS: real / HLE | Save |
|---|---|---|---|---|---|
| Golden Sun: Dark Dawn (BO5E) | title, naming, the 26 000-frame intro, the first field (the lookout cabin) under player control, the Psynergy menu | identical where the two are in step (title, menus, intro pages: 0 to a few hundred dots apart, all animation phase); 11-40 frames behind by the end of the intro | correlation 0.97-0.995 with the reference where in step, spectra 0.96-0.999, levels within 0.4 dB | identical (to frame 6000 compared) | 512 KB FLASH detected (the game uses 256 KB); format at boot as the reference; no in-game save reached |
| Pokemon Mystery Dungeon: Explorers of Darkness (YFYE) | intro demo, title, personality quiz (incl. the touch-and-hold aura test), partner and hero naming, the story, Beach Cave B1F, a fight (Corsola defeated) | identical where in step; the random choices (demo cast, quiz questions, so the hero) differ: the game's per-frame RNG starts 2 frames apart | spectra 0.99-0.996, levels within 0.4 dB; some notes a 5.2 ms sequencer tick apart | identical through the first dungeon (after the logo fix below) | 512 KB FLASH detected (the reference uses 256 KB); the first save is after the dungeon |
| Pokemon SoulSilver (IPGE) | p12 (New Bark Town) plus: the touch menu's SAVE (saved and continued from), Professor Elm's lab and his talk | p12 checkpoints as before (3000/5000/8000 hashes unchanged); 6000 now identical | (unchanged, 0.99 correlation) | identical | 512 KB FLASH; our save and the reference's both continue identically; the two saves differ in 6 bytes |

## Method

Tools added this round (all on the branch):

- `ndsref --ram-peek A1,..` / `--ram-shots F1,..` read the core's main RAM
  through the public libretro memory API; `ndsrun --ram-peek` /
  `--ram-shots` do the same on ours (the CPU's view, untimed: an earlier
  version read through the timed bus and moved the game). With them a
  game's own frame counter and RNG word can be followed in both runs.
  `ndsref --sram-out` writes the core's save memory; `ndsrun --ram-poke
  A=V@F` writes a RAM word before frame F.
- Debug builds (`-d:ndsdebug`) print, with `--pcs`, the master cycles the
  ARM9 spent held by the geometry FIFO and by DMA each frame; `--watch`
  shows r0, lr and the frame.

Scratch scripts (`/Users/matt/.claude/jobs/b618fe8e/tmp/fleet/commercial/`):
`run1.sh` / `ref1.sh` (one game, ours / the reference, fresh empty save,
`--rtc 2004-01-01`, the user's firmware name on the reference),
`cmp.sh` (ndsdiff per shot), `phase.sh` and `pcmp.sh` (phase-tolerant: our
frame against every reference frame within K), `wavcmp.py` (per window:
the best lag, waveform correlation at it, a lag-free spectral
correlation, levels), `peekcmp.py` / `peekoff.py` / `findcnt.py` (counters
and RNG words in RAM), `bright.py` / `fitb.py` / `fitp2.py` (the
disp_bright fits), `perf.sh` (host instructions per frame).

The reference runs with its firmware nickname, favourite colour and
language taken from the user's firmware (the options are in
docs/oracles.md): its own default nickname otherwise ends up in Golden
Sun's naming screen.

Differences are classified as **phase** (the same picture a few frames
apart: timing), **RNG** (a random choice taken from a different state:
timing upstream), **rendering** (a pixel the hardware would draw
differently), **input** (a press landing on a different game state).

## The scripts

Each is a single `--press` list in the scratch `scripts/` directory;
described here by its generators (`A every 40 from 3100 to 40000` means
`A@3100,A@3140,...`). Run with `--rtc 2004-01-01 --save EMPTY.sav` and the
dumps.

**Golden Sun: Dark Dawn** (`scripts/gs_dd_field.txt`, 40 000 frames):
`TOUCH:128:100@1450+4` (title), `START@2200` (accept the firmware
nickname), A every 50 from 2300 to 2950, `START@3000`, A every 40 from
3100 to 40000. Title at ~410, naming at 2200, the scrolling intro pages
3000-26000 (unskippable), the lookout cabin from ~27000, player control
on the cliff by ~28000-34000. From a state at 40000: `X` opens the menu
(Psynergy, Items, Status, Encyclopedia, Atlas, Settings), `X,A,A,RIGHT,A`
casts Growth. The way on (and the first battle) needs Growth on the sprout
below the cliff, which the ring at the player's feet does not reach from
the ledge: not solved blind.

**Pokemon Mystery Dungeon: Explorers of Darkness**
(`scripts/pmd_eod_dungeon.txt`, 32 000 frames): START every 60 from 2400
to 2640 (title), A every 30 from 2700 to 5670 (quiz), A every 30 from 6700
to 7470, `TOUCH:128:96@7600-8200` (hold the stylus until told: a short
touch only says "Don't move your finger quite yet"), A every 30 from 8300
to 9990, `START@10020,A@10050,UP@10150,A@10200` (partner nickname: START
moves to END, the Yes/No cursor starts on No), A every 30 from 10300 to
23700, `UP@23740,A@23780` (hero name "aaaaaaaaaa", Yes), A every 30 from
23850 to 32000. Beach Cave B1F by ~26000; A attacks; at 32000 "Corsola was
defeated!".

**SoulSilver** (`scripts/ss_p12.txt` = the fleet's p12;
`scripts/ss_continue_save.txt`: from `soulsilver_newbark.sav`,
`START@700,START@1000,A@1300,TOUCH:123:76@1600+8`, A every 100 from 1700
to 2100: the touch menu's SAVE, "There is already a saved file. Is it OK
to overwrite?", saved by ~3300; `scripts/ss_elm_lab.txt`: from the same
save, LEFT 1550-1700, UP 1700-1730, LEFT 1800-1818, UP 1830-1870 (into the
lab), UP 2120-2220 (to Elm), A every 20 to 6700: Elm's talk).

## Golden Sun: Dark Dawn

### Found and fixed

1. **3D blended over 2D one 5-bit step dark** (rendering). The intro's
   parchment (an alpha-16 3D map over a black backdrop, captured and shown
   by VRAM display) was one step darker than the reference on 56 % of the
   bottom screen. Root cause: engine A's colour effects and master
   brightness ran on 5-bit channels; GBATEK gives MASTER_BRIGHT on 6-bit
   intensities and the 3D layer is 6-bit. New test ROM `disp_bright`
   (55 settings, 2D, 3D and 3D-over-2D samples) read from the reference
   without `--depth5` gives exact forms: 2D colours enter as 2c, 3D ones as
   their 6-bit value; BLDALPHA `min(63,(A*EVA + B*EVB + 8)/16)`, BLDY up
   `(16I + (63-I)EVY + 8)/16`, down `(I(16-EVY) + 8)/16`, 3D over a 2nd
   target `(C3(a+1) + C2(31-a) + 16)/32`, MASTER_BRIGHT up
   `(16I + (63-I)F)/16`, down `I(16-F)/16` truncated (GBATEK's own
   formulas, the result truncated; truncating `I*F/16` first fails 448 of
   1120 samples). The composite keeps each channel's dropped low bit
   (`engine2d.nim` `lsb`) for master brightness; capture stays 15-bit as
   GBATEK says. Ours now equals the reference's top five bits on every
   disp_bright frame (`nds_3d_test`), the GS parchment exactly, BlocksDS
   `video_effects/blending` (open since round 6) exactly. Cost: +0.7 %
   host instructions on the GS title.
2. **The title ran at 40 fps against the reference's 60** (timing). The
   game's logic counter advanced 2 per 3 frames on its title (its clouds
   drifted apart from the reference's, 8000-15000 dots by frame 1400). The
   ARM9 was busy only 45 % of each frame; the debug stall counters showed
   DMA holding it for 35-74 % (an H-blank DMA of 128 words a line from main
   RAM to VRAM, plus GX FIFO feeding). Our DMA cost was a placeholder (2
   cycles per 16-bit side, +4 a block). New ROM `disp_dmatime` times
   immediate DMAs between every region pair on the reference: 32-bit unit
   = read (main RAM 1, VRAM/palette 2, others 1) + write (main RAM 2,
   VRAM/palette 2, others 1); 16-bit unit 2; main to main 18/16; +1-2 a
   block. With that model the title's game loop keeps pace (the logic
   counter's gap stops at the load-time offsets), the title is 3670 dots
   from the reference's best-matching frame instead of 22 000.
   (`io/dma.nim`, `nds_compat_test`; ARM7 DMA and the GBA slot keep the
   estimate.)

### Left (classified)

- **Loads take longer than on the reference** (timing): the title fade
  starts ~5 frames late (frame 405), loading the menu costs ~9 more,
  naming ~6 more; by the end of the intro pages ours is 11-40 frames
  behind. Where the two are in step every compared frame matches to a few
  hundred dots (2000: exact 11 frames later on the reference; 10 000:
  exact 13 later; 6000-22 000: 850-1600 dots, animation phase). The
  card's ROM transfer is *faster* in ours (below), so the extra load time
  is CPU-side; `disp_dmatime`'s clock row
  shows our two back-to-back 3-read timer samples taking 50 bus cycles
  against the reference's 22: ARM9 I/O reads cost more in ours. Left for
  the timing work (docs/nds/accuracy.md).
- **Late in the intro the runs part** (RNG/input): from ~26 000 the
  reference's Matthew has 41 HP where ours has 42 (stats rolled from a
  different random state when the hero was named) and its cutscenes run
  ~30+ frames ahead, so the same presses land on different text; both
  reach the cabin with player control.
- **The first battle and a save**: both need the Growth puzzle on the
  cliff (above); saving is not on the prologue's menu. Not reached.
- **Save chip**: the game addresses only 0-3FFFFh (16 headers of 32 bytes
  every 4000h, read with 03h; no RDID), so 256 KB FLASH; ours starts a
  24-bit chip at 512 KB (docs/nds/saves.md) and keeps it, the reference
  reports 256 KB. The format written at boot is the same (the reference's
  fresh memory is 00h, ours FFh like an erased chip). Harmless; exports
  are 512 KB.
- Sound: as table. The constant ~50 ms offset seen for every game is the
  reference's output path (SoulSilver too, 51.9 ms), not a game effect.

## Pokemon Mystery Dungeon: Explorers of Darkness

### Found and fixed

1. **Text fades one step off** (rendering): the copyright screen's
   master-brightness fade never matched any reference frame (575 dots):
   the 6-bit fix above. Frames 500, 600, 700, 2000, 3800, 4200 now
   identical.
2. **HLE BIOS: the quiz background differed from the real BIOS's**. The
   game copies FFFF0024h onwards into RAM; the real BIOS9 holds the
   cartridge logo at FFFF0020h (checked against the user's dump at run
   time), our HLE image had code there, and the wave background drawn from
   it moved. The HLE image now leaves 20h-BBh free and direct boot copies
   the card header's own logo (0C0h-15Bh) in (`hle_bios.s`, `boot.nim`,
   `nds_compat_test`). Identical under both BIOSes through 32 000 frames.
3. **Direct-boot info** (found while hunting the boot offset): 27FF874h
   (firmware[026h], the user's 4F5Dh), 27FF860h (cart[038h]), 27FF890h
   (B0002A22h) were 0 and the empty GBA slot's flags byte 27FFC35h was FFh;
   now as the real firmware leaves them (the dumps booted with `--boot
   firmware`).

### Left (classified)

- **RNG** (timing): the game advances a 16-bit RNG (020A604Ch) every
  frame from its first frame; ours starts 2 frames earlier (frame 23
  against 25) and stays 2 ahead, and some events land a few frames
  differently (the RNG words realign after them), so the intro demo's
  cast (Riolu/Meowth here, Charmander/Chikorita there), the quiz questions
  and so the hero (Torchic here) and partner (Totodile; Pikachu there)
  differ. Poking the reference's RNG value into ours at the quiz start did
  not make the questions agree (they draw from more than this word). The
  2 frames are the boot: in frame 2 ours has already copied the ARM7's
  code to 023E0000 where the reference has not. Everything not random is
  identical frame for frame (title, menus, intro movie at 0 dots).
- With the same script the reference ends at the hero naming screen
  (its random path asks other questions), so dungeon scenes cannot be
  compared frame for frame; the dungeon's picture (tiles, sprites, HUD,
  message log) shows no artefact in ours.
- **Save**: the first save is offered after Beach Cave; not reached. The
  chip: 24-bit FLASH, 512 KB in ours, 256 KB on the reference (as GS).

## SoulSilver beyond p12

- **Save**: the touch menu's SAVE from the New Bark save; the game writes
  for ~1000 frames ("Saving a lot of data..."). Our save and the
  reference's (`ndsref --sram`/`--sram-out` from the same file and
  presses) differ in 6 bytes (0x2C, 0x23F5, 0x241A, 0x246A, 0xF626-7:
  play time / clock fields); a fresh boot continues from either one
  identically in ours. A save cut off mid-write (a run ended at 3000)
  gives "The save file is corrupted. The previous save file will be
  loaded." on both emulators alike.
- **Elm's lab**: the aide's and Elm's dialogues render as on the reference
  in the frames compared. The starter machine and so a wild battle, the
  Pokégear (not on the menu yet with this save) and a Pokemon Center were
  not reached: the machine did not respond to A from the tile reached.
- **The p12 residuals** (frames 6600: 15 dots, 8000: 283 dots): 6600 is
  the 3D bedroom's edge dots (docs/nds/3d-edges.md, known). 8000 is not
  rendering: walking downstairs (map load at ~7180) the fade-in starts a
  few frames later in ours (load time, as GS), and the p12 script's A
  presses every 20 frames then hit Mom's text one press later, so at 8000
  ours shows "Professo" where the reference shows "Professor Elm,": the
  same dialogue ~20 frames behind. Frame 6000 (32 dots before) is now
  identical; 3000/5000/8000 hashes unchanged (e4b66d68 / 6cf51b7e /
  ae4536a1), the continue check unchanged (hle 6b9b805f, bios 228bc64d).

## Card timing (measured, not changed)

`disp_cardtime` reads the card by CPU polling and by slot-1 DMA. By DMA
ours moves a word every 20 bus cycles (4 bytes at 6.7 MHz, GBATEK) and
the reference every ~23; its first word comes ~38 byte times after the
command, ours after 12. With the games' header setting (gap1 = 657h) a
200h block takes 3.5 % longer on the reference. GBATEK's numbers (1.6
MB/s for that setting) match ours, so ours is kept; the reference row is
in docs/oracles.md.

## Speed (for the perf work)

Host instructions per emulated frame (`-d:danger`, from a save state, 600
frames; fps measured on a machine at load ~40, so only the instruction
counts compare):

| Scene | host instr / frame | fps (loaded host) |
|---|---|---|
| SS title (3D Lugia) | 10.5 M | 232 |
| SS bedroom (3D) | 35.6 M | 93 |
| SS New Bark overworld | 74.7 M | 33 |
| GS title (dual-screen 3D + capture) | **186.0 M** | 10 |
| GS intro pages (3D parchment) | **131.8 M** | 18 |
| GS first field (lookout cabin) | **153.3 M** | 17 |
| PMD intro demo | 27.1 M | 118 |
| PMD personality quiz | 45.5 M | 44 |
| PMD dungeon B1F | 27.1 M | 59 |

Outliers: every Golden Sun scene (130-190 M a frame: ~2.5x SoulSilver's
overworld, which already runs below 60 fps on a phone) -- it renders 3D
on both screens (capture every frame) with heavy H-blank and GX-FIFO DMA;
and SoulSilver's overworld at 75 M against its 3D bedroom's 36 M.

## Also open

- ARM9 I/O read cost (above): a likely cause of the longer loads; a
  hardware or test-ROM measurement of ARM9 I/O and timer reads would
  settle it.
- Capture blending (`gpu.nim` capture_line) still truncates per GBATEK
  where the reference rounds (docs/oracles.md); `video_capture/motion_blur`
  trails differ for it.
- 24-bit FLASH size: a 256 KB game gets a 512 KB chip; starting at 256 KB
  and growing would match the reference, but changes what RDID answers
  before a game has addressed past 256 KB (docs/nds/saves.md), so it was
  left for the save-chip work.
