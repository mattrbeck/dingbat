# The phone held upright

What a phone held upright (coarse pointer, portrait, under 700 px wide)
shows while a game runs, web (`web/styles.css` "Phone held upright: the
picture gets the room") and the iOS app (`ios/Dingbat/Sources/PlayLayout.swift`
`portrait`). Tablets held upright keep their own tier.

| | |
|---|---|
| The top bar | Folded off the top while a game runs ("Hide the top bar while playing", on by default). A tap on the picture, or the letterbox round it, brings it down; another takes it away. The same tap rules as a phone held sideways: one finger, short and still, a thumb's width clear of any control; a DS game's touch screen is the stylus's. The first time, a toast says so. Off, the bar stays in its place above the picture. |
| L, Select, Start, R | One slim row over the d-pad and the face buttons: the shoulders at the strip's edges (76 x 30), the pills between them (60 x 24, 10 apart). They replace the full-width shoulder row and the pill row under the clusters (46 and 34 tall, 172 and 150 wide on a 390-wide phone). Each reaches 7 px past its drawn edge above and below, so they are smaller to see than to hit. A Game Boy game has no shoulders: the pills alone, centred. Large controls keeps the slim row (it grows the d-pad and face buttons only). |
| The d-pad and face buttons | Unchanged in size and spacing. |
| The picture | A window 12 px in from each side of the screen (`--stage-inset`), never edge to edge; it takes the rest of the room above the controls. |

What the room comes to on a 393 x 852 iPhone (59 / 34 safe areas), DS
stacked: the screens were 267 px wide (the DS bar already folded) and are now 310 (+16 %; 13 mini 253 to 297, Pro Max 306 to 349, SE 200 to 244);
a GBA game's picture goes from the full 393 to 369, letterboxed as before.

## Considered

- The slim row under the clusters, where Select and Start were: Start under
  the thumb, but L and R at the bottom of the strip are nowhere near where
  a console has them.
- L and R over the clusters and Select/Start stacked between the d-pad and
  B: the most room of all for the picture, but the pills crowd the d-pad's
  down arm on a 375-wide phone.
