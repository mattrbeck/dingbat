import SwiftUI
import UIKit

// The play screen's arrangement (web styles.css "On-screen gamepad",
// "Mobile landscape", "Tablet touch layouts"): where the bar, the stage and
// every touch control go for the device, the orientation and the settings.
// Sizes are the web's px caps in points. Matt's rule holds throughout: the
// controls never change size or spacing to make room; the stage yields.

/// Global-coordinate rects of every drawn touch control, so a tap on the
/// picture can keep clear of them.
final class PadGeometry {
    static let shared = PadGeometry()
    var rects: [CGRect] = []
}

/// Where each touch control sits, in the play screen's own coordinates.
struct ControlFrames: Equatable {
    var dpad: CGRect = .null        // the d-pad
    var joyRegion: CGRect = .null   // the joystick's touch region
    var joyBase: CGRect = .null     // the joystick base's home (the d-pad's size)
    var a: CGRect = .null
    var b: CGRect = .null
    var l: CGRect = .null           // .null on Game Boy games (no shoulders)
    var r: CGRect = .null
    var select: CGRect = .null
    var start: CGRect = .null
    /// The DS's X and Y (.null for the other systems).
    var x: CGRect = .null
    var y: CGRect = .null
    /// The pills' touch area reaches past the drawn pill above and below
    /// (phone landscape), never sideways.
    var pillSlop: CGFloat = 0
    /// A DS game on a phone: Select/Start are 28pt circles labelled
    /// underneath, each hit 8pt past its circle and on its label (web
    /// .pad-pill::before inset -8px -8px -20px).
    var circlePills = false
    /// A DS game on a phone held upright: the short L/R, hit 6pt above and
    /// below.
    var shoulderSlop: CGFloat = 0
    /// A DS game on a phone held upright: the short L/R's look.
    var shortShoulders = false

    func hitRect(_ id: Int) -> CGRect {
        func pill(_ r: CGRect) -> CGRect {
            circlePills ? CGRect(x: r.minX - 8, y: r.minY - 8, width: r.width + 16, height: r.height + 28)
                        : r.insetBy(dx: 0, dy: -pillSlop)
        }
        switch id {
        case 4: return a
        case 5: return b
        case 6: return pill(select)
        case 7: return pill(start)
        case 8: return l.insetBy(dx: 0, dy: -shoulderSlop)
        case 9: return r.insetBy(dx: 0, dy: -shoulderSlop)
        case 10: return x
        case 11: return y
        default: return .null
        }
    }

    func drawn(joystick: Bool) -> [CGRect] {
        [joystick ? joyBase : dpad, a, b, x, y, l, r, select, start].filter { !$0.isNull }
    }
}

struct PlayGeometry: Equatable {
    enum Mode { case portrait, phoneLandscape, tabletLandscape }

    var mode: Mode = .portrait
    var size: CGSize = .zero
    var safe = EdgeInsets()
    /// The 52pt bar row; in phone landscape its resting place when down.
    var bar: CGRect = .zero
    var stage: CGRect = .zero
    /// The portrait control strip (its background), or .null.
    var strip: CGRect = .null
    /// nil while the touch controls are hidden (a controller is connected).
    var controls: ControlFrames?
    var large = false
    var pillFont: CGFloat = 11
    /// The bar folds off the top until a tap on the picture: a phone held
    /// sideways, a DS game on a phone held upright with "Hide the top bar"
    /// on, and a phone upright beside a status column when that makes the
    /// picture bigger (foldBesideColumn).
    var barFolds = false
    /// DS, phone held sideways: the widest the screens may be (web ndsAvail).
    var ndsMaxWidth: CGFloat?
    /// DS, phone held upright: the screens at the stage's top.
    var ndsTop = false
    /// DS half-folded: the screens' places, fixed (ndsPortrait).
    var ndsFixed: NdsUtil.Layout?
    /// Where on the stage the picture goes, in the stage's coordinates; nil
    /// for the whole stage, centred.
    var pictureBox: CGRect?

    var stageContext: StageContext {
        StageContext(barFolds: barFolds, ndsMaxWidth: ndsMaxWidth, ndsTop: ndsTop, pictureBox: pictureBox,
                     ndsFixed: ndsFixed)
    }

    static let barHeight: CGFloat = 52

    struct Inputs: Equatable {
        var size: CGSize
        var safe: EdgeInsets
        var compactHeight: Bool
        var regular: Bool
        var isGB: Bool
        var large: Bool
        var hidden: Bool
        /// A Nintendo DS game; its own layout only where this says so.
        var nds = false
        var ndsBarHide = true
        var joystick = false
        /// Settings › Video › Picture held upright (beside a status column).
        var upright: Settings.UprightPicture = .clear
        /// A foldable's hinge partly open (HingeState).
        var halfFolded = false
        /// DS: the screens swapped (NdsState.swap).
        var ndsSwap = false
    }

    /// Wider than the folded Duo's cover (466pt) yet laid out as a phone
    /// held upright: the Duo's inner screen (669pt). The controls keep the
    /// cover's sizes there, not the width's (a thumb is the same size), and
    /// take the compact measures.
    static let coverWidth: CGFloat = 466

    /// Where the crease runs, half-folded and held upright (the inner
    /// screen's middle); nil otherwise.
    private func crease(_ i: Inputs) -> CGFloat? {
        let w = i.size.width, h = i.size.height
        guard i.halfFolded, h > w, w > Self.coverWidth, w < 700 else { return nil }
        return (h / 2).rounded()
    }

    static func make(_ i: Inputs) -> PlayGeometry {
        var g = PlayGeometry()
        g.size = i.size
        g.safe = i.safe
        g.large = i.large
        let landscape = i.size.width > i.size.height
        if i.compactHeight && landscape {
            g.mode = .phoneLandscape
            g.barFolds = true
            g.phoneLandscape(i)
        } else if i.regular && landscape {
            g.mode = .tabletLandscape
            g.tabletLandscape(i)
        } else if i.nds && i.size.width < 700 {
            g.mode = .portrait
            g.ndsPortrait(i)
        } else {
            g.mode = .portrait
            g.portrait(i)
        }
        return g
    }

    // MARK: DS, phone held upright

    /// web styles.css "DS on a phone held upright: the two screens get the
    /// room". The bar folds off the top (with "Hide the top bar") and the
    /// top screen goes up to the notch or Dynamic Island; L/R are short at
    /// the strip's top corners; Select/Start small labelled circles at the
    /// bottom between the d-pad and B; the d-pad and face buttons keep their
    /// size, their row exactly the d-pad's height on the strip's bottom
    /// padding. Only the screens give or take room.
    private mutating func ndsPortrait(_ i: Inputs) {
        let w = size.width, h = size.height
        let padTop: CGFloat = 8, gap: CGFloat = 8, shoulderH: CGFloat = 28
        // web --nds-pad-b: the home indicator's inset less 12, plus a 16pt
        // lift off the bottom edge on a phone that has one (the screens give
        // up that height).
        let padBottom = max(10, safe.bottom - 12) + (safe.bottom > 0 ? 16 : 0)
        // Side insets held upright are a status column (PlayGeometry.portrait).
        let padL: CGFloat = 16, padR: CGFloat = 16
        let cw = w - padL - padR
        // The controls' sizes: from the width, never past the cover's.
        let cs = min(cw, Self.coverWidth - padL - padR)
        let mainH = i.large ? min(cs * 0.62, 330) : min(cs * 0.46, 240)
        let stripH = padTop + shoulderH + gap + mainH + padBottom
        ndsTop = true
        bar = CGRect(x: safe.leading, y: safe.top, width: w - safe.leading - safe.trailing, height: Self.barHeight)
        // --nds-top: where the notch or Dynamic Island ends on a model
        // PhoneCutout knows; otherwise the status-bar inset less what
        // usually lies beside the cut-out, 14pt on a notched phone and 11pt
        // on a Dynamic Island one (an inset of 54pt or more); a plain 20pt
        // status bar keeps the whole inset.
        let ndsTopY = PhoneCutout.bottom(screen: size, safeTop: safe.top)
            ?? (safe.top > 53 ? safe.top - 11 : safe.top > 20 ? safe.top - 14 : safe.top)
        barFolds = i.ndsBarHide
        let stageTop = barFolds ? ndsTopY : bar.maxY
        guard !i.hidden else {
            stage = CGRect(x: 0, y: stageTop, width: w, height: max(0, h - safe.bottom - stageTop))
            return
        }
        strip = CGRect(x: 0, y: h - stripH, width: w, height: stripH)
        stage = CGRect(x: 0, y: stageTop, width: w, height: max(0, strip.minY - stageTop))

        // Half-folded: the console itself. The top screen above the crease
        // as wide as it goes; below it the touch screen between L and R,
        // and the d-pad and buttons on the bottom padding. One composite
        // (the stage, down to the controls) with each screen's place in it.
        let c = crease(i)
        let mainTop = h - padBottom - mainH
        if let c {
            barFolds = true
            strip = CGRect(x: 0, y: mainTop - padTop, width: w, height: h - mainTop + padTop)
            stage = CGRect(x: 0, y: 0, width: w, height: strip.minY)
            let upper = c - 6 - safe.top
            let tw = min(w - 16, upper * 4 / 3), th = tw * 3 / 4
            let topRect = CGRect(x: (w - tw) / 2, y: c - 6 - th, width: tw, height: th)
            let lowTop = c + 6, lowH = strip.minY - 6 - lowTop
            let side = padL + 120 + 8
            let bw = max(0, min(w - 2 * side, lowH * 4 / 3)), bh = bw * 3 / 4
            let bottomRect = CGRect(x: (w - bw) / 2, y: lowTop + (lowH - bh) / 2, width: bw, height: bh)
            var lay = NdsUtil.Layout()
            lay.mode = .stack
            lay.shape = "fold"
            lay.swap = i.ndsSwap
            lay.gap = 0
            lay.uw = w; lay.uh = stage.height; lay.w = w; lay.h = stage.height
            lay.top = i.ndsSwap ? bottomRect : topRect
            lay.bottom = i.ndsSwap ? topRect : bottomRect
            lay.scale = 1
            ndsFixed = lay
        }

        var f = ControlFrames()
        let top = c.map { $0 + 6 } ?? strip.minY + padTop
        f.l = CGRect(x: padL, y: top, width: 120, height: shoulderH)
        f.r = CGRect(x: w - padR - 120, y: top, width: 120, height: shoulderH)
        f.shoulderSlop = 6
        f.shortShoulders = true
        let y0 = c != nil ? mainTop : top + shoulderH + gap
        let cb = mainH
        let dpad = i.large ? min(0.62 * cs, 330, cb) : min(0.46 * cs, 240, cb)
        f.dpad = CGRect(x: padL, y: y0 + (cb - dpad) / 2, width: dpad, height: dpad)
        f.joyRegion = CGRect(x: padL, y: y0, width: cw / 2, height: cb)
        f.joyBase = CGRect(x: f.joyRegion.midX - dpad / 2, y: f.joyRegion.midY - dpad / 2, width: dpad, height: dpad)
        let btn = i.large ? min(0.42 * cs / 2.8, 74, cb / 2.8) : min(0.46 * cs / 2.7, 84, cb / 2.7)
        placeDiamond(&f, in: CGRect(x: w - padR - 2.5 * btn, y: y0, width: 2.5 * btn, height: cb), button: btn)
        // 28pt circles 22pt apart, centred, their bottoms 12pt above the
        // strip's bottom padding.
        let cy = strip.maxY - padBottom - 12 - 28
        f.select = CGRect(x: w / 2 - 11 - 28, y: cy, width: 28, height: 28)
        f.start = CGRect(x: w / 2 + 11, y: cy, width: 28, height: 28)
        f.circlePills = true
        controls = f
    }

    /// web body.nds-mode #ab: A/B/X/Y a diamond of the same buttons (X top,
    /// Y left, A right, B bottom), 0.75 of a button from the centre each
    /// way, in a box 2.5 buttons wide.
    private func placeDiamond(_ f: inout ControlFrames, in ab: CGRect, button btn: CGFloat) {
        let cx = ab.midX, cy = ab.midY, d = 0.75 * btn
        func at(_ x: CGFloat, _ y: CGFloat) -> CGRect { CGRect(x: x - btn / 2, y: y - btn / 2, width: btn, height: btn) }
        f.a = at(cx + d, cy)
        f.y = at(cx - d, cy)
        f.x = at(cx, cy - d)
        f.b = at(cx, cy + d)
    }

    // MARK: a phone upright beside a status column

    /// The iPhone Duo folded: its cover screen keeps a status column at the
    /// side (84pt on the right, the clock under a camera at its top), and
    /// under the bar and over the controls the picture is short of height,
    /// not width. When folding the bar away makes it bigger, the bar folds
    /// (a tap on the picture brings it down) and the picture takes the room
    /// clear of the column, 16pt in from the other edge and the top so the
    /// screen's rounded corner keeps off it, as near the centre as that
    /// allows. "Under the camera" gives it the whole width from the top
    /// edge, centred, the camera over its corner.
    private mutating func foldBesideColumn(_ i: Inputs) {
        let colL = safe.leading, colR = safe.trailing
        guard colL + colR > 0 else { return }
        let w = size.width, bottom = strip.minY
        let aspect: CGFloat = i.isGB ? 10.0 / 9 : 3.0 / 2
        func fitWidth(_ r: CGRect) -> CGFloat { max(0, min(r.width, r.height * aspect)) }
        let m: CGFloat = 16
        let box: CGRect
        if i.upright == .camera {
            box = CGRect(x: 0, y: safe.top, width: w, height: bottom - safe.top)
        } else {
            let x0 = colL > 0 ? colL : m, x1 = w - (colR > 0 ? colR : m)
            box = CGRect(x: x0, y: safe.top + m, width: x1 - x0, height: bottom - safe.top - m)
        }
        let pw = fitWidth(box)
        guard pw > fitWidth(stage) * 1.04 else { return }
        barFolds = true
        stage = CGRect(x: 0, y: safe.top, width: w, height: max(0, bottom - safe.top))
        let ph = pw / aspect
        let cx = min(max(w / 2, box.minX + pw / 2), box.maxX - pw / 2)
        pictureBox = CGRect(x: cx - pw / 2, y: box.midY - ph / 2, width: pw, height: ph)
            .offsetBy(dx: -stage.minX, dy: -stage.minY)
    }

    /// "Full width, smaller buttons": the bar stays, and the picture takes
    /// the room from 16pt under the bar (clear of the camera at the
    /// column's top: the Duo's ends 67pt down) to the compact strip,
    /// centred, as wide as the screen where the height allows (GBA 466 x
    /// 311 on the Duo; GB, taller, 401 x 361).
    private mutating func fullWidthPicture(_ i: Inputs) {
        let aspect: CGFloat = i.isGB ? 10.0 / 9 : 3.0 / 2
        let top = max(stage.minY, bar.maxY + 16)
        let room = CGRect(x: 0, y: top, width: size.width, height: max(0, stage.maxY - top))
        let pw = max(0, min(room.width, room.height * aspect)), ph = pw / aspect
        pictureBox = CGRect(x: room.midX - pw / 2, y: room.midY - ph / 2, width: pw, height: ph)
            .offsetBy(dx: -stage.minX, dy: -stage.minY)
    }

    // MARK: portrait (phones, and tablets held upright)

    /// web #controls: a grid of the L/R row, the main cluster and
    /// Select/Start under the stage. Short portrait (<= 620pt tall) packs the
    /// chrome rows tighter, never the d-pad or the face buttons.
    private mutating func portrait(_ i: Inputs) {
        let w = size.width, h = size.height
        let short = h <= 620
        let tablet = w >= 700
        // "Full width, smaller buttons" beside a status column: the DS
        // cluster's measures (ndsPortrait) -- short L/R at the strip's top
        // corners, the main row 0.46 of the width, Select/Start small
        // circles inside it -- so the picture gets the height it needs.
        let wide = !tablet && w > Self.coverWidth
        let fullOption = !tablet && i.upright == .full && safe.leading + safe.trailing > 0
        let compact = fullOption || wide
        let c = crease(i)
        let padTop: CGFloat = compact ? 8 : (short ? 10 : 14)
        let padBottom: CGFloat = compact ? max(10, safe.bottom - 12) + (safe.bottom > 0 ? 16 : 0)
                                         : (short ? 12 : 16) + safe.bottom
        let gap: CGFloat = compact ? 8 : (short ? 10 : 14)
        // A phone held upright has side insets only for a status column
        // beside the picture: the iPhone Duo folded keeps 84pt on the right
        // for the clock, under a camera at its top. The bar keeps clear of
        // it; the controls under the stage need not, with the status bar
        // hidden, and centre on the screen.
        let padL: CGFloat = 16, padR: CGFloat = 16
        let shoulderH: CGFloat = compact ? 28 : (i.large ? 38 : (short ? 36 : 46))
        let pillH: CGFloat = i.large ? 28 : (short ? 28 : 34)
        pillFont = i.large ? 10 : 11
        // The controls' sizes: from the width, never past the cover's.
        let cs = min(w - padL - padR, Self.coverWidth - padL - padR)
        let mainH = compact ? (i.large ? min(0.62 * cs, 330) : min(0.46 * cs, 240))
                            : (i.large ? min(0.64 * w, 330) : min(0.54 * w, 290))
        let showLR = !i.isGB
        // Portrait tablets place Select/Start absolutely, inboard of the
        // clusters; their grid row collapses (its gap stays). Compact, they
        // sit in the main row.
        let stripH = compact ? padTop + (showLR ? shoulderH + gap : 0) + mainH + padBottom
                             : padTop + (showLR ? shoulderH + gap : 0) + mainH + gap + (tablet ? 0 : pillH) + padBottom

        bar = CGRect(x: safe.leading, y: safe.top, width: w - safe.leading - safe.trailing, height: Self.barHeight)
        let stageTop = bar.maxY
        guard !i.hidden else {
            stage = CGRect(x: 0, y: stageTop, width: w, height: max(0, h - safe.bottom - stageTop))
            return
        }
        // Half-folded: the picture above the crease (the bar folded off
        // it), the controls centred below.
        let floorY = c.map { $0 + (h - $0 + stripH) / 2 } ?? h
        strip = CGRect(x: 0, y: floorY - stripH, width: w, height: stripH)
        stage = CGRect(x: 0, y: stageTop, width: w, height: max(0, strip.minY - stageTop))
        if let c {
            barFolds = true
            stage = CGRect(x: 0, y: safe.top, width: w, height: max(0, c - 8 - safe.top))
        } else if fullOption {
            fullWidthPicture(i)
        } else if !tablet && !wide {
            foldBesideColumn(i)
        }

        var f = ControlFrames()
        let cw = w - padL - padR
        let top = strip.minY + padTop
        if showLR && compact {
            f.l = CGRect(x: padL, y: top, width: 120, height: shoulderH)
            f.r = CGRect(x: w - padR - 120, y: top, width: 120, height: shoulderH)
            f.shoulderSlop = 6
            f.shortShoulders = true
        } else if showLR {
            let sw = tablet ? 200 : (cw - 14) / 2
            f.l = CGRect(x: padL, y: top, width: sw, height: shoulderH)
            f.r = CGRect(x: w - padR - sw, y: top, width: sw, height: shoulderH)
        }
        let y0 = top + (showLR ? shoulderH + gap : 0)
        let cb = mainH
        let dpad = i.large ? min(0.62 * cs, 330, cb) : min(0.46 * cs, 240, cb)
        f.dpad = CGRect(x: padL, y: y0 + (cb - dpad) / 2, width: dpad, height: dpad)
        f.joyRegion = CGRect(x: padL, y: y0, width: cw / 2, height: cb)
        // Upright, the base sits centred in its region.
        f.joyBase = CGRect(x: f.joyRegion.midX - dpad / 2, y: f.joyRegion.midY - dpad / 2, width: dpad, height: dpad)
        let btn = i.large ? min(0.42 * cs / 2.8, 74, cb / 2.8) : min(0.46 * cs / 2.7, 84, cb / 2.7)
        let abW = btn * (i.nds ? 2.5 : i.large ? 2.05 : 2.2)
        let abH = min(0.46 * cs, 240, cb)
        let ab = CGRect(x: w - padR - abW, y: y0 + (cb - abH) / 2, width: abW, height: abH)
        if i.nds { placeDiamond(&f, in: ab, button: btn) } else { placeAB(&f, in: ab, button: btn) }

        let pw: CGFloat = i.large ? 120 : 150
        if compact {
            // ndsPortrait's: 28pt circles 22pt apart, centred, 12pt above
            // the strip's bottom padding.
            let cy = strip.maxY - padBottom - 12 - 28
            f.select = CGRect(x: w / 2 - 11 - 28, y: cy, width: 28, height: 28)
            f.start = CGRect(x: w / 2 + 11, y: cy, width: 28, height: 28)
            f.circlePills = true
        } else if tablet {
            // web: insets clear the cluster widths; the bottom lines the
            // pills up with the clusters' bottoms.
            let left = 28 + safe.leading + (i.large ? 330 : 240)
            let right = w - (28 + safe.trailing + (i.large ? 152 : 185))
            let bottom = h - safe.bottom - (i.large ? 44 : 55)
            placePills(&f, from: left, to: right, bottom: bottom, width: 150, height: pillH)
        } else {
            let each = min(pw, (cw - 18) / 2)
            let y = strip.maxY - padBottom - pillH
            f.select = CGRect(x: w / 2 - 9 - each, y: y, width: each, height: pillH)
            f.start = CGRect(x: w / 2 + 9, y: y, width: each, height: pillH)
        }
        // Half-folded, the strip's colour is the whole lower half's.
        if let c { strip = CGRect(x: 0, y: c, width: w, height: h - c) }
        controls = f
    }

    // MARK: phone landscape

    /// web max-height 500 landscape: the stage takes the whole screen, the
    /// bar waits off the top, and see-through pads hug the screen edges.
    private mutating func phoneLandscape(_ i: Inputs) {
        let w = size.width, h = size.height
        bar = CGRect(x: 0, y: 0, width: w, height: Self.barHeight)
        stage = CGRect(origin: .zero, size: size)
        guard !i.hidden else { return }
        let left = safe.leading + 6, right = w - safe.trailing - 6
        let top = safe.top + 6, bottom = h - safe.bottom - 6
        let cw = right - left, cb = bottom - top
        let base = bottom - 8   // #main-controls' padding-bottom: the clusters' bottom line
        var f = ControlFrames()
        let dpad = i.large ? min(0.40 * cw, 210, 0.92 * cb) : min(0.32 * cw, 158, 0.76 * cb)
        f.dpad = CGRect(x: left, y: base - dpad, width: dpad, height: dpad)
        f.joyRegion = CGRect(x: left, y: top, width: cw / 2, height: base - top)
        f.joyBase = f.dpad   // sideways, where the d-pad would rest
        let btn = i.large ? min(0.40 * cw / 2.6, 82, 0.92 * cb / 2.6) : min(0.32 * cw / 2.6, 62, 0.76 * cb / 2.6)
        let abH = i.large ? min(0.46 * cw, 240, 0.92 * cb) : min(0.32 * cw, 180, 0.76 * cb)
        if i.nds {
            let abW = btn * 2.5
            placeDiamond(&f, in: CGRect(x: right - abW, y: base - abH, width: abW, height: abH), button: btn)
        } else {
            let abW = btn * 2.2
            placeAB(&f, in: CGRect(x: right - abW, y: base - abH, width: abW, height: abH), button: btn)
        }
        if !i.isGB {
            let sw: CGFloat = i.large ? 120 : 104, sh: CGFloat = i.large ? 46 : 44
            f.l = CGRect(x: left, y: top, width: sw, height: sh)
            f.r = CGRect(x: right - sw, y: top, width: sw, height: sh)
        }
        // Select/Start: labelled pills just inboard of each cluster, their
        // bottoms level with the clusters'.
        pillFont = i.large ? 12 : 11
        if i.nds {
            // web "DS on a phone held sideways": Select/Start the upright
            // phone's small labelled circles, in the right rail centred
            // under R (18pt below it, 22pt apart), so the screens get the
            // whole height between the d-pad and the face buttons.
            let cy = f.r.maxY + 18
            f.select = CGRect(x: f.r.midX - 11 - 28, y: cy, width: 28, height: 28)
            f.start = CGRect(x: f.r.midX + 11, y: cy, width: 28, height: 28)
            f.circlePills = true
            // web ndsAvail: symmetric about the stage's centre, 8pt clear of
            // the d-pad (or the stick's base) and of the face buttons.
            let lEdge = i.joystick ? f.joyBase.maxX : f.dpad.maxX
            let mid = stage.midX
            let half = min(mid - lEdge, f.y.minX - mid) - 8
            if half > 0 { ndsMaxWidth = 2 * half }
            controls = f
            return
        }
        let pw: CGFloat = i.large ? 84 : 76, ph: CGFloat = i.large ? 40 : 36
        let abW = btn * 2.2
        let rowL = f.dpad.maxX + 20, rowR = f.a.maxX - abW - 20
        f.select = CGRect(x: rowL, y: base - ph, width: pw, height: ph)
        f.start = CGRect(x: rowR - pw, y: base - ph, width: pw, height: ph)
        f.pillSlop = i.large ? 4 : 6
        controls = f
    }

    // MARK: tablet landscape

    /// web min-height 501 landscape: the bar stays, the stage is padded by a
    /// rail each side, and the clusters pin to the bottom corners with the
    /// shoulders above them and the pills inboard.
    private mutating func tabletLandscape(_ i: Inputs) {
        let w = size.width, h = size.height
        bar = CGRect(x: safe.leading, y: safe.top, width: w - safe.leading - safe.trailing, height: Self.barHeight)
        let top = bar.maxY
        guard !i.hidden else {
            stage = CGRect(x: 0, y: top, width: w, height: max(0, h - safe.bottom - top))
            return
        }
        let rail: CGFloat = i.large ? 274 : 224
        let pillH: CGFloat = 34
        pillFont = 11
        // The 60pt bottom band keeps the frame off the pills.
        let bottomBand = max(60, safe.bottom + 18 + pillH + 8)
        stage = CGRect(x: rail, y: top, width: max(0, w - 2 * rail), height: max(0, h - bottomBand - top))
        let left = 14 + safe.leading, right = w - 14 - safe.trailing
        let base = h - 10 - safe.bottom - 8
        var f = ControlFrames()
        let dpad: CGFloat = i.large ? 240 : 190
        f.dpad = CGRect(x: left, y: base - dpad, width: dpad, height: dpad)
        f.joyRegion = CGRect(x: left, y: top + 10, width: (right - left) / 2, height: base - top - 10)
        f.joyBase = f.dpad
        let btn: CGFloat = i.large ? 92 : 73
        let abW = btn * (i.nds ? 2.5 : 2.2)
        if i.nds {
            placeDiamond(&f, in: CGRect(x: right - abW, y: base - dpad, width: abW, height: dpad), button: btn)
        } else {
            placeAB(&f, in: CGRect(x: right - abW, y: base - dpad, width: abW, height: dpad), button: btn)
        }
        if !i.isGB {
            let sw: CGFloat = i.large ? 170 : 150
            let y = h - (10 + safe.bottom + dpad + 22) - 46
            f.l = CGRect(x: left, y: y, width: sw, height: 46)
            f.r = CGRect(x: right - sw, y: y, width: sw, height: 46)
        }
        let pl = 26 + safe.leading + (i.large ? 240 : 190)
        let pr = w - (26 + safe.trailing + (i.large ? 203 : 161))
        placePills(&f, from: pl, to: pr, bottom: h - 18 - safe.bottom, width: 150, height: pillH)
        controls = f
    }

    // MARK: shared pieces

    /// web #ab: A top-right (14% down), B bottom-left (14% up).
    private func placeAB(_ f: inout ControlFrames, in ab: CGRect, button btn: CGFloat) {
        f.a = CGRect(x: ab.maxX - btn, y: ab.minY + 0.14 * ab.height, width: btn, height: btn)
        f.b = CGRect(x: ab.minX, y: ab.maxY - 0.14 * ab.height - btn, width: btn, height: btn)
    }

    /// A space-between row; the pills shrink rather than collide.
    private func placePills(_ f: inout ControlFrames, from left: CGFloat, to right: CGFloat,
                            bottom: CGFloat, width: CGFloat, height: CGFloat) {
        let each = max(44, min(width, (right - left) / 2))
        f.select = CGRect(x: left, y: bottom - height, width: each, height: height)
        f.start = CGRect(x: right - each, y: bottom - height, width: each, height: height)
    }
}

/// Arranges the stage, the top bar and the touch controls for the device
/// and orientation. `stage` fills the rect it is given.
struct PlayLayout<Stage: View, Bar: View>: View {
    let stage: Stage
    let bar: Bar

    @EnvironmentObject var model: AppModel
    @EnvironmentObject var settings: Settings
    @Environment(\.palette) var palette
    @Environment(\.verticalSizeClass) var vSize
    @Environment(\.horizontalSizeClass) var hSize
    // Not the session itself: it changes every frame.
    @State private var isGB = GameSession.shared.isGB
    @State private var isNDS = GameSession.shared.isNDS
    @State private var game = GameSession.shared.game
    @ObservedObject private var nds = NdsState.shared
    @ObservedObject private var hinge = HingeState.shared

    var body: some View {
        // The outer reader sees the safe area; the inner one spans the
        // whole screen, and every inset is applied by hand.
        GeometryReader { outer in
            content(safe: outer.safeAreaInsets)
        }
        .background(HingeObserver())
        .onReceive(GameSession.shared.$isGB) { isGB = $0 }
        .onReceive(GameSession.shared.$isNDS) { isNDS = $0 }
        .onReceive(GameSession.shared.$game) { game = $0 }
    }

    private func content(safe: EdgeInsets) -> some View {
        GeometryReader { geo in
            let g = PlayGeometry.make(.init(
                size: geo.size, safe: safe, compactHeight: vSize == .compact,
                regular: hSize == .regular && vSize == .regular, isGB: isGB,
                large: settings.largeControls, hidden: model.gamepadHidesTouch,
                nds: isNDS, ndsBarHide: nds.barHide, joystick: settings.controlStyle == .joystick,
                upright: settings.uprightPicture, halfFolded: hinge.halfFolded, ndsSwap: nds.swap))
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                (palette.chromeTransparent ? Color.clear : palette.stage)
                    .frame(width: g.size.width, height: g.size.height)
                stage
                    .environment(\.stageContext, g.stageContext)
                    .frame(width: g.stage.width, height: g.stage.height)
                    .offset(x: g.stage.minX, y: g.stage.minY)
                if !g.strip.isNull {
                    ControlStrip(rect: g.strip, safeBottom: g.safe.bottom,
                                 stripeBase: g.ndsTop ? max(10, g.safe.bottom - 12) + 48 : nil)
                }
                if let f = g.controls {
                    TouchControls(frames: f, geometry: g)
                    TouchRouter(frames: f, enabled: !model.menuOpen,
                                blockedTop: g.barFolds && barDown ? g.bar.maxY : 0)
                        .frame(width: g.size.width, height: g.size.height)
                }
                barLayer(g)
            }
            .frame(width: g.size.width, height: g.size.height, alignment: .topLeading)
            .onAppear { publish(g, origin: origin) }
            .onChange(of: g) { publish($0, origin: origin) }
            .onChange(of: game) { _ in publish(g, origin: origin) }
            .onChange(of: settings.controlStyle) { _ in publish(g, origin: origin) }
        }
        .ignoresSafeArea()
        .onDisappear { PadGeometry.shared.rects = [] }
    }

    private var barDown: Bool { model.topbarOpen || model.menuOpen }

    @ViewBuilder
    private func barLayer(_ g: PlayGeometry) -> some View {
        if g.mode == .portrait && g.barFolds {
            // A DS game on a phone held upright: the bar waits off the top
            // and comes down over the top screen (web nds-bar-hide), its
            // colour running up behind the status area.
            VStack(spacing: 0) {
                Group {
                    if palette.chromeTransparent { palette.bg } else { palette.topbarTop }
                }
                .frame(height: g.bar.minY)
                bar
                    .padding(.leading, g.safe.leading)
                    .padding(.trailing, g.safe.trailing)
                    .frame(width: g.size.width, height: PlayGeometry.barHeight)
                    .background(
                        palette.chromeTransparent
                            ? AnyView(palette.bg)
                            : AnyView(LinearGradient(colors: [palette.topbarTop, palette.topbarBottom],
                                                     startPoint: .top, endPoint: .bottom)))
                    .overlay(Rectangle().fill(palette.frameLine).frame(height: 1), alignment: .bottom)
            }
            .frame(width: g.size.width)
            .shadow(color: .black.opacity(barDown ? 0.55 : 0), radius: 13, y: 10)
            .offset(y: barDown ? 0 : -(g.bar.maxY + 30))
            .animation(.easeOut(duration: 0.2), value: barDown)
        } else {
            barLayerStandard(g)
        }
    }

    @ViewBuilder
    private func barLayerStandard(_ g: PlayGeometry) -> some View {
        switch g.mode {
        case .phoneLandscape:
            // Off the top until a tap on the picture (or the menu) brings
            // it down; padded past the notch. Pure Black gives it the black.
            bar
                .padding(.leading, g.safe.leading)
                .padding(.trailing, g.safe.trailing)
                .frame(width: g.size.width, height: PlayGeometry.barHeight)
                .background(
                    palette.chromeTransparent
                        ? AnyView(palette.bg)
                        : AnyView(LinearGradient(colors: [palette.topbarTop, palette.topbarBottom],
                                                 startPoint: .top, endPoint: .bottom)))
                .overlay(Rectangle().fill(palette.frameLine).frame(height: 1), alignment: .bottom)
                .shadow(color: .black.opacity(barDown ? 0.55 : 0), radius: 13, y: 10)
                .offset(y: barDown ? 0 : -(PlayGeometry.barHeight + 30))
                .animation(.easeOut(duration: 0.2), value: barDown)
        case .portrait, .tabletLandscape:
            // The bar's colour runs up behind the status area.
            Group {
                if palette.chromeTransparent { Color.clear } else { palette.topbarTop }
            }
            .frame(width: g.size.width, height: g.bar.minY)
            Group {
                if palette.chromeTransparent { Color.clear } else {
                    LinearGradient(colors: [palette.topbarTop, palette.topbarBottom],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
            .frame(width: g.size.width, height: g.bar.height)
            // A bar narrower than the screen (beside a status column): its
            // rule runs the whole width with the colour.
            .overlay(alignment: .bottom) {
                if !palette.chromeTransparent && g.bar.width < g.size.width {
                    Rectangle().fill(palette.frameLine).frame(height: 1)
                }
            }
            .offset(y: g.bar.minY)
            bar
                .frame(width: g.bar.width, height: g.bar.height)
                .offset(x: g.bar.minX, y: g.bar.minY)
        }
    }

    private func publish(_ g: PlayGeometry, origin: CGPoint) {
        PadGeometry.shared.rects = (g.controls?.drawn(joystick: settings.controlStyle == .joystick) ?? []).map { $0.offsetBy(dx: origin.x, dy: origin.y) }
        if g.barFolds && GameSession.shared.game != nil { BarTapHint.showIfNeeded() }
        if g.controls == nil { TouchRouterView.current?.releaseAll() }
    }
}

/// The portrait control strip's background (web #controls): the strip
/// gradient under a hairline, and a device theme's two pinstripes through
/// the bottom of the clusters (Famicom).
struct ControlStrip: View {
    @Environment(\.palette) var palette
    let rect: CGRect
    let safeBottom: CGFloat
    /// DS upright: the pinstripes run through the bottom of the clusters,
    /// which sit on the strip's bottom padding (this far up, then 12pt more).
    var stripeBase: CGFloat?

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !palette.chromeTransparent {
                LinearGradient(colors: [palette.controlStripTop, palette.controlStripBottom],
                               startPoint: .top, endPoint: .bottom)
            }
            if let stripe = palette.panelStripe {
                if let b = stripeBase {
                    stripe.frame(height: 4).offset(y: rect.height - b)
                    stripe.frame(height: 4).offset(y: rect.height - b + 12)
                } else {
                    stripe.frame(height: 4).offset(y: rect.height - safeBottom - 116)
                    stripe.frame(height: 4).offset(y: rect.height - safeBottom - 104)
                }
            }
            palette.frameLine.frame(height: 1)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }
}
