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
    /// The bar is folded away, so a tap on the picture toggles it.
    var barFolds = false
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
    /// The pills' touch area reaches past the drawn pill above and below
    /// (phone landscape, phone upright), never sideways.
    var pillSlop: CGFloat = 0
    /// The same for the shoulders (phone upright's slim row).
    var shoulderSlop: CGFloat = 0

    func hitRect(_ id: Int) -> CGRect {
        switch id {
        case 4: return a
        case 5: return b
        case 6: return select.insetBy(dx: 0, dy: -pillSlop)
        case 7: return start.insetBy(dx: 0, dy: -pillSlop)
        case 8: return l.isNull ? l : l.insetBy(dx: 0, dy: -shoulderSlop)
        case 9: return r.isNull ? r : r.insetBy(dx: 0, dy: -shoulderSlop)
        default: return .null
        }
    }

    func drawn(joystick: Bool) -> [CGRect] {
        [joystick ? joyBase : dpad, a, b, l, r, select, start].filter { !$0.isNull }
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
    var shoulderFont: CGFloat = 15
    /// The bar waits off the top until a tap on the picture brings it down:
    /// always on a phone held sideways, and on one held upright with "Hide
    /// the top bar while playing" on.
    var barFolds = false

    static let barHeight: CGFloat = 52
    /// Phone upright: the picture is a window this far in from each side
    /// (web --stage-inset).
    static let stageInset: CGFloat = 12

    struct Inputs: Equatable {
        var size: CGSize
        var safe: EdgeInsets
        var compactHeight: Bool
        var regular: Bool
        var isGB: Bool
        var large: Bool
        var hidden: Bool
        /// Settings › Controls › Hide the top bar while playing.
        var foldBar: Bool = true
    }

    static func make(_ i: Inputs) -> PlayGeometry {
        var g = PlayGeometry()
        g.size = i.size
        g.safe = i.safe
        g.large = i.large
        let landscape = i.size.width > i.size.height
        if i.compactHeight && landscape {
            g.mode = .phoneLandscape
            g.phoneLandscape(i)
        } else if i.regular && landscape {
            g.mode = .tabletLandscape
            g.tabletLandscape(i)
        } else {
            g.mode = .portrait
            g.portrait(i)
        }
        return g
    }

    // MARK: portrait (phones, and tablets held upright)

    /// web #controls: a grid of the L/R row, the main cluster and
    /// Select/Start under the stage. Short portrait (<= 620pt tall) packs the
    /// chrome rows tighter, never the d-pad or the face buttons.
    private mutating func portrait(_ i: Inputs) {
        let w = size.width, h = size.height
        let short = h <= 620
        let tablet = w >= 700
        if !tablet { return phonePortrait(i) }
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
        let abW = btn * (i.large ? 2.05 : 2.2)
        let abH = min(0.46 * cw, 240, cb)
        let ab = CGRect(x: w - padR - abW, y: y0 + (cb - abH) / 2, width: abW, height: abH)
        placeAB(&f, in: ab, button: btn)

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

    // MARK: phone upright

    /// web "Phone held upright: the picture gets the room": L, Select,
    /// Start and R share one slim row over the d-pad and the face buttons
    /// (the shoulders at the edges, the pills between them), the bar folds
    /// off the top until a tap on the picture (Settings › Controls › Hide
    /// the top bar while playing), and the picture is a window 12pt in from
    /// the sides. The d-pad and the face buttons keep their size.
    private mutating func phonePortrait(_ i: Inputs) {
        let w = size.width, h = size.height
        let short = h <= 620
        let padTop: CGFloat = short ? 10 : 14
        let padBottom: CGFloat = (short ? 12 : 16) + safe.bottom
        let gap: CGFloat = 12
        let padL = 16 + safe.leading, padR = 16 + safe.trailing
        let rowH: CGFloat = 30
        let mainH = i.large ? min(0.64 * w, 330) : min(0.54 * w, 290)
        pillFont = 9
        shoulderFont = 12
        barFolds = i.foldBar
        bar = CGRect(x: safe.leading, y: safe.top, width: w - safe.leading - safe.trailing, height: Self.barHeight)
        let stageTop = barFolds ? safe.top : bar.maxY
        let sx = Self.stageInset + safe.leading
        let sw = max(0, w - 2 * Self.stageInset - safe.leading - safe.trailing)
        guard !i.hidden else {
            stage = CGRect(x: sx, y: stageTop, width: sw, height: max(0, h - safe.bottom - stageTop))
            return
        }
        let stripH = padTop + rowH + gap + mainH + padBottom
        strip = CGRect(x: 0, y: h - stripH, width: w, height: stripH)
        stage = CGRect(x: sx, y: stageTop, width: sw, height: max(0, strip.minY - stageTop))

        var f = ControlFrames()
        let cw = w - padL - padR
        let top = strip.minY + padTop
        if !i.isGB {
            let lw: CGFloat = 76
            f.l = CGRect(x: padL, y: top, width: lw, height: rowH)
            f.r = CGRect(x: w - padR - lw, y: top, width: lw, height: rowH)
        }
        let pw: CGFloat = 60, ph: CGFloat = 24
        let mid = padL + cw / 2
        f.select = CGRect(x: mid - 5 - pw, y: top + (rowH - ph) / 2, width: pw, height: ph)
        f.start = CGRect(x: mid + 5, y: top + (rowH - ph) / 2, width: pw, height: ph)
        // Smaller to see, not to hit: 7pt past the drawn edge above and below.
        f.pillSlop = 7
        f.shoulderSlop = 7
        placeCluster(&f, y0: top + rowH + gap, height: mainH, left: padL, width: cw, large: i.large)
        controls = f
    }

    /// The d-pad (or the joystick's region) and the face buttons in a row
    /// `height` tall from `y0` (web #main-controls), as portrait has them.
    private func placeCluster(_ f: inout ControlFrames, y0: CGFloat, height cb: CGFloat,
                              left padL: CGFloat, width cw: CGFloat, large: Bool) {
        let dpad = large ? min(0.62 * cw, 330, cb) : min(0.46 * cw, 240, cb)
        f.dpad = CGRect(x: padL, y: y0 + (cb - dpad) / 2, width: dpad, height: dpad)
        f.joyRegion = CGRect(x: padL, y: y0, width: cw / 2, height: cb)
        // Upright, the base sits centred in its region.
        f.joyBase = CGRect(x: f.joyRegion.midX - dpad / 2, y: f.joyRegion.midY - dpad / 2, width: dpad, height: dpad)
        let btn = large ? min(0.42 * cw / 2.8, 74, cb / 2.8) : min(0.46 * cw / 2.7, 84, cb / 2.7)
        let abW = btn * (large ? 2.05 : 2.2)
        let abH = min(0.46 * cw, 240, cb)
        let ab = CGRect(x: padL + cw - abW, y: y0 + (cb - abH) / 2, width: abW, height: abH)
        placeAB(&f, in: ab, button: btn)
    }

    // MARK: phone landscape

    /// web max-height 500 landscape: the stage takes the whole screen, the
    /// bar waits off the top, and see-through pads hug the screen edges.
    private mutating func phoneLandscape(_ i: Inputs) {
        let w = size.width, h = size.height
        barFolds = true
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
        let abW = btn * 2.2
        let abH = i.large ? min(0.46 * cw, 240, 0.92 * cb) : min(0.32 * cw, 180, 0.76 * cb)
        placeAB(&f, in: CGRect(x: right - abW, y: base - abH, width: abW, height: abH), button: btn)
        if !i.isGB {
            let sw: CGFloat = i.large ? 120 : 104, sh: CGFloat = i.large ? 46 : 44
            f.l = CGRect(x: left, y: top, width: sw, height: sh)
            f.r = CGRect(x: right - sw, y: top, width: sw, height: sh)
        }
        // Select/Start: labelled pills just inboard of each cluster, their
        // bottoms level with the clusters'.
        let pw: CGFloat = i.large ? 84 : 76, ph: CGFloat = i.large ? 40 : 36
        pillFont = i.large ? 12 : 11
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
        let abW = btn * 2.2
        placeAB(&f, in: CGRect(x: right - abW, y: base - dpad, width: abW, height: dpad), button: btn)
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
    @State private var game = GameSession.shared.game

    var body: some View {
        // The outer reader sees the safe area; the inner one spans the
        // whole screen, and every inset is applied by hand.
        GeometryReader { outer in
            content(safe: outer.safeAreaInsets)
        }
        .onReceive(GameSession.shared.$isGB) { isGB = $0 }
        .onReceive(GameSession.shared.$game) { game = $0 }
    }

    private func content(safe: EdgeInsets) -> some View {
        GeometryReader { geo in
            let g = PlayGeometry.make(.init(
                size: geo.size, safe: safe, compactHeight: vSize == .compact,
                regular: hSize == .regular && vSize == .regular, isGB: isGB,
                large: settings.largeControls, hidden: model.gamepadHidesTouch,
                foldBar: settings.foldBar))
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                (palette.chromeTransparent ? Color.clear : palette.stage)
                    .frame(width: g.size.width, height: g.size.height)
                stage
                    .frame(width: g.stage.width, height: g.stage.height)
                    .offset(x: g.stage.minX, y: g.stage.minY)
                if !g.strip.isNull {
                    ControlStrip(rect: g.strip, safeBottom: g.safe.bottom)
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
            .onChange(of: settings.foldBar) { _ in publish(g, origin: origin) }
        }
        .ignoresSafeArea()
        .onDisappear { PadGeometry.shared.rects = [] }
    }

    private var barDown: Bool { model.topbarOpen || model.menuOpen }

    @ViewBuilder
    private func barLayer(_ g: PlayGeometry) -> some View {
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
        case .portrait where g.barFolds:
            // Folded off the top until a tap on the picture (or the menu)
            // brings it down over the picture; its colour runs up behind
            // the status area with it.
            ZStack(alignment: .topLeading) {
                Group {
                    if palette.chromeTransparent { palette.bg } else {
                        LinearGradient(colors: [palette.topbarTop, palette.topbarBottom],
                                       startPoint: .top, endPoint: .bottom)
                    }
                }
                .frame(width: g.size.width, height: g.bar.maxY)
                bar
                    .frame(width: g.bar.width, height: g.bar.height)
                    .offset(x: g.bar.minX, y: g.bar.minY)
            }
            .frame(width: g.size.width, height: g.bar.maxY, alignment: .topLeading)
            .overlay(Rectangle().fill(palette.frameLine).frame(height: 1), alignment: .bottom)
            .shadow(color: .black.opacity(barDown ? 0.55 : 0), radius: 13, y: 10)
            .offset(y: barDown ? 0 : -(g.bar.maxY + 30))
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
        PadGeometry.shared.barFolds = g.barFolds
        if g.barFolds && GameSession.shared.game != nil { BarTapHint.showIfNeeded() }
        // Unfolded, the bar is in its place: nothing left open over the picture.
        if !g.barFolds && model.topbarOpen { model.topbarOpen = false }
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

    var body: some View {
        ZStack(alignment: .topLeading) {
            if !palette.chromeTransparent {
                LinearGradient(colors: [palette.controlStripTop, palette.controlStripBottom],
                               startPoint: .top, endPoint: .bottom)
            }
            if let stripe = palette.panelStripe {
                stripe.frame(height: 4).offset(y: rect.height - safeBottom - 116)
                stripe.frame(height: 4).offset(y: rect.height - safeBottom - 104)
            }
            palette.frameLine.frame(height: 1)
        }
        .frame(width: rect.width, height: rect.height, alignment: .topLeading)
        .offset(x: rect.minX, y: rect.minY)
        .allowsHitTesting(false)
    }
}
