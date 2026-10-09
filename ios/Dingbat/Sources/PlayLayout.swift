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
    /// sideways, and a DS game on a phone held upright with "Hide the top
    /// bar" on.
    var barFolds = false
    /// DS, phone held sideways: the widest the screens may be (web ndsAvail).
    var ndsMaxWidth: CGFloat?
    /// DS, phone held upright: the screens at the stage's top.
    var ndsTop = false

    var stageContext: StageContext {
        StageContext(barFolds: barFolds, ndsMaxWidth: ndsMaxWidth, ndsTop: ndsTop)
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
        let padL = 16 + safe.leading, padR = 16 + safe.trailing
        let cw = w - padL - padR
        let mainH = i.large ? min(cw * 0.62, 330) : min(cw * 0.46, 240)
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

        var f = ControlFrames()
        let top = strip.minY + padTop
        f.l = CGRect(x: padL, y: top, width: 120, height: shoulderH)
        f.r = CGRect(x: w - padR - 120, y: top, width: 120, height: shoulderH)
        f.shoulderSlop = 6
        f.shortShoulders = true
        let y0 = top + shoulderH + gap
        let cb = mainH
        let dpad = i.large ? min(0.62 * cw, 330, cb) : min(0.46 * cw, 240, cb)
        f.dpad = CGRect(x: padL, y: y0 + (cb - dpad) / 2, width: dpad, height: dpad)
        f.joyRegion = CGRect(x: padL, y: y0, width: cw / 2, height: cb)
        f.joyBase = CGRect(x: f.joyRegion.midX - dpad / 2, y: f.joyRegion.midY - dpad / 2, width: dpad, height: dpad)
        let btn = i.large ? min(0.42 * cw / 2.8, 74, cb / 2.8) : min(0.46 * cw / 2.7, 84, cb / 2.7)
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

    // MARK: portrait (phones, and tablets held upright)

    /// web #controls: a grid of the L/R row, the main cluster and
    /// Select/Start under the stage. Short portrait (<= 620pt tall) packs the
    /// chrome rows tighter, never the d-pad or the face buttons.
    private mutating func portrait(_ i: Inputs) {
        let w = size.width, h = size.height
        let short = h <= 620
        let tablet = w >= 700
        let padTop: CGFloat = short ? 10 : 14
        let padBottom: CGFloat = (short ? 12 : 16) + safe.bottom
        let gap: CGFloat = short ? 10 : 14
        let padL = 16 + safe.leading, padR = 16 + safe.trailing
        let shoulderH: CGFloat = i.large ? 38 : (short ? 36 : 46)
        let pillH: CGFloat = i.large ? 28 : (short ? 28 : 34)
        pillFont = i.large ? 10 : 11
        let mainH = i.large ? min(0.64 * w, 330) : min(0.54 * w, 290)
        let showLR = !i.isGB
        // Portrait tablets place Select/Start absolutely, inboard of the
        // clusters; their grid row collapses (its gap stays).
        let stripH = padTop + (showLR ? shoulderH + gap : 0) + mainH + gap + (tablet ? 0 : pillH) + padBottom

        bar = CGRect(x: safe.leading, y: safe.top, width: w - safe.leading - safe.trailing, height: Self.barHeight)
        let stageTop = bar.maxY
        guard !i.hidden else {
            stage = CGRect(x: 0, y: stageTop, width: w, height: max(0, h - safe.bottom - stageTop))
            return
        }
        strip = CGRect(x: 0, y: h - stripH, width: w, height: stripH)
        stage = CGRect(x: 0, y: stageTop, width: w, height: max(0, strip.minY - stageTop))

        var f = ControlFrames()
        let cw = w - padL - padR
        let top = strip.minY + padTop
        if showLR {
            let sw = tablet ? 200 : (cw - 14) / 2
            f.l = CGRect(x: padL, y: top, width: sw, height: shoulderH)
            f.r = CGRect(x: w - padR - sw, y: top, width: sw, height: shoulderH)
        }
        let y0 = top + (showLR ? shoulderH + gap : 0)
        let cb = mainH
        let dpad = i.large ? min(0.62 * cw, 330, cb) : min(0.46 * cw, 240, cb)
        f.dpad = CGRect(x: padL, y: y0 + (cb - dpad) / 2, width: dpad, height: dpad)
        f.joyRegion = CGRect(x: padL, y: y0, width: cw / 2, height: cb)
        // Upright, the base sits centred in its region.
        f.joyBase = CGRect(x: f.joyRegion.midX - dpad / 2, y: f.joyRegion.midY - dpad / 2, width: dpad, height: dpad)
        let btn = i.large ? min(0.42 * cw / 2.8, 74, cb / 2.8) : min(0.46 * cw / 2.7, 84, cb / 2.7)
        let abW = btn * (i.nds ? 2.5 : i.large ? 2.05 : 2.2)
        let abH = min(0.46 * cw, 240, cb)
        let ab = CGRect(x: w - padR - abW, y: y0 + (cb - abH) / 2, width: abW, height: abH)
        if i.nds { placeDiamond(&f, in: ab, button: btn) } else { placeAB(&f, in: ab, button: btn) }

        let pw: CGFloat = i.large ? 120 : 150
        if tablet {
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

    var body: some View {
        // The outer reader sees the safe area; the inner one spans the
        // whole screen, and every inset is applied by hand.
        GeometryReader { outer in
            content(safe: outer.safeAreaInsets)
        }
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
                nds: isNDS, ndsBarHide: nds.barHide, joystick: settings.controlStyle == .joystick))
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
