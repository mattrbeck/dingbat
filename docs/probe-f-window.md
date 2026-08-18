# probe (f): the window is in the acid-hell path, and it costs a pixel

**ROM:** `tools/gbprobe/probe_f_winbar.gb` — probe (e)'s bands with the window
live from x = 8, built `-DWIN_LIVE=1`. Same paging as probe (e): LEFT/RIGHT
picks SCX 0-7, UP/DOWN picks the object X (`FF` = off), and the top-left
prints the two settings as hex so a photograph names itself.

**Read with:** `tools/gbprobe/read_probe_d_photo.py <photo.jpg> --skip-top 16
--bands`, exactly as probe (e).

## Why this probe exists

`cgb-acid-hell`'s two pixels are at x = 80 on ly 68 and 69, and x = 80 is a
**window** pixel — its trace reads `WINHIT ly=68 dot=126 lx=26`, so the window
is live across the whole right-hand side of the failing line. Everything else
on that line had been eliminated: the object is at X = 1 (`R = 5`), a cell
where dingbat and the oracle agree, and seventeen knob values across the
tile-select, window-enable and object-penalty families all leave the residual
at exactly 2 px.

The narrowest surviving description was that acid-hell pulses **window-enable
and tile-select in the same write**, a pair no mealybug row covers. probe (f)
was built to test that as a differential — window live, pulsing tile-select
alone against pulsing both bits — because with the anchor, the bands and the
window identical in both arms, whatever probe (e)'s STAT-LYC anchor
contributes cancels.

## Result: the pair is refuted, the window itself is not

At SCX 4, objects off:

| arm | SameBoy | dingbat |
|---|---|---|
| plain (no window) | `20 28 28 36 36 44 44 52 52 60 60 68 68 76` | `28 36 36 44 44 52 52 60 60 68 68 76 76 84` |
| window live | `16 24 24 32 32 40 40 48 48 56 56 64 64 72` | `24 31 32 39 40 47 48 55 56 63 64 71 72 79` |
| window live + bit 5 in the pulse | *identical to the row above* | *identical to the row above* |

**Putting window-enable into the pulse changes nothing, in either emulator.**
So the coupled pair is not the missing mechanism, and that hypothesis is dead.

**But the window on its own is.** Take the plain arm's familiar 8-dot offset
out of the windowed arm — subtract 8 from dingbat — and it does not reconcile:

    sameboy       16  24  24  32  32  40  40  48 ...
    dingbat - 8   16  23  24  31  32  39  40  47 ...

Every *alternate* band sits **one pixel left**. The plain arm has no such
error: there the two staircases differ by a clean 8 dots and nothing else. So
with the window live dingbat acquires a per-band, one-pixel error that it does
not have without it — the same scale, and the same alternating shape, as
acid-hell's single wrong pixel on two adjacent lines.

That makes the window the first mechanism in this whole search that is both
implicated by acid-hell's own trace and measurably wrong on an independent
instrument.

## What would help from hardware

SameBoy has been validated against the GBA SP on all eight probe (e) settings
and renders `cgb-acid-hell` pixel-exact, which is why it has been trusted for
the rest of this work. **It has not been checked in this corner** — window
live under an LCDC.4 pulse — and a structural change to the window path
should not be derived from an emulator in a corner no photograph has seen.

One sitting, eight shots, same method as probe (e):

1. Boot `probe_f_winbar.gb`. It comes up at `00 FF` (SCX 0, objects off).
2. Photograph the whole screen at **SCX 0, 1, 2, 3, 4, 5, 6, 7**, objects off
   (`FF`) throughout — check the two hex bytes top-left before each shot.

The prediction to test is SameBoy's: a clean doubled staircase stepping 8 every
two bands (`16 24 24 32 32 40 …` at SCX 4, one pixel left per SCX increment).
If hardware shows that, dingbat's alternating one-pixel error is confirmed a
model bug and the window path is where the remaining four dots live. If
hardware shows dingbat's alternating pattern instead, then SameBoy is wrong
here, acid-hell's reference is measuring something else, and the search moves
back to the anchor.

Objects can stay off for all eight — the object arm of this probe is already
covered by probe (e), and the window is the variable under test.
