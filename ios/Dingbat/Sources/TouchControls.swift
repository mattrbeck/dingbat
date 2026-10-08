import SwiftUI
import UIKit

// The on-screen gamepad (web #controls): d-pad or joystick, A/B, L/R,
// Select/Start. SwiftUI draws the pads at the frames PlayGeometry gives them;
// one invisible UIKit view on top routes every touch (web dpadTouchStart/
// Move/End, the standalone buttons, joystickTouchStart/Move). Input ids:
// 0 Up, 1 Down, 2 Left, 3 Right, 4 A, 5 B, 6 Select, 7 Start, 8 L, 9 R.

/// What the pads show as held, written by the router.
final class TouchPadState: ObservableObject {
    static let shared = TouchPadState()
    /// Lit arms and buttons (a diagonal lights both arms).
    @Published var lit: Set<Int> = []
    /// Joystick: the base's offset from home (floating mode drags it), the
    /// knob's from the base, and the rim arc's direction (nil = off).
    @Published var joyBase: CGSize = .zero
    @Published var joyKnob: CGSize = .zero
    @Published var joyRim: Angle?
}

// MARK: - Skin

/// How a pad looks: the portrait/tablet pads, or one of Settings ›
/// Controls › Buttons in landscape on a phone held sideways.
enum PadLook { case normal, outline, bold, solid }

/// The pad colours for a look, from the theme (web .pad-btn, .pad-face,
/// .pad-pill, #dpad and the phone-landscape overrides, with their CSS
/// specificity worked out: a d-pad keeps its own border when pressed, and
/// a theme's ring survives the see-through looks).
struct PadSkin {
    enum Part { case pad, face, pill, dpad }

    let p: Palette
    let look: PadLook

    var seeThrough: Bool { look == .outline || look == .bold }

    /// --pad-line: the see-through looks' line (Solid: the plain border).
    var line: Color {
        switch look {
        case .solid: return p.border2
        case .bold: return p.isLight ? Color(red: 24 / 255, green: 32 / 255, blue: 52 / 255, opacity: 0.8) : .white.opacity(0.9)
        default: return p.isLight ? Color(red: 24 / 255, green: 32 / 255, blue: 52 / 255, opacity: 0.4) : .white.opacity(0.28)
        }
    }

    var glyph: Color { p.text.opacity(look == .bold ? 0.9 : (p.isLight ? 0.6 : 0.5)) }
    /// Bold's halo, so the line or its halo contrasts with any picture.
    var halo: Color? { look == .bold ? (p.isLight ? .white.opacity(0.85) : .black.opacity(0.85)) : nil }
    var insetHi: Color { p.isLight ? .white.opacity(0.85) : .white.opacity(0.09) }

    func fill(_ part: Part, pressed: Bool) -> [Color]? {
        if seeThrough { return nil }
        if pressed { return [p.accentTintTop, p.padPressedBottom] }
        if look == .solid { return [p.surface3, p.surface1] }
        switch part {
        case .face: return [p.abTopC, p.abBottomC]
        case .pill: return [p.pillTopC, p.pillBottomC]
        case .pad, .dpad: return [p.padTop, p.padBottom]
        }
    }

    func border(_ part: Part, pressed: Bool) -> Color {
        if part == .dpad {
            if look == .normal { return p.dpadBorderC }
            return p.dpadBorder ?? line
        }
        if pressed { return p.accent.opacity(seeThrough ? 0.7 : 0.55) }
        switch look {
        case .normal:
            switch part {
            case .face: return p.abBorderC
            default: return p.padBorder
            }
        case .solid: return p.border2
        case .outline, .bold: return part == .face ? (p.abRing ?? line) : line
        }
    }

    func borderWidth(_ part: Part) -> CGFloat {
        let base: CGFloat
        switch part {
        case .face: base = p.abBorderWidth
        case .dpad: base = p.dpadBorderWidth
        default: base = 1
        }
        return look == .bold ? max(2, base) : base
    }

    func label(_ part: Part, pressed: Bool) -> Color {
        if pressed { return p.accent }
        switch look {
        case .outline, .bold: return glyph
        case .solid: return p.textDim
        case .normal:
            switch part {
            case .face: return p.abLabelC
            case .pill: return p.pillLabelC
            default: return p.padLabel
            }
        }
    }

    /// The cross's inner bar lines (where the bars meet), or nil.
    var barLine: Color? {
        if seeThrough || !p.dpadBarLine { return nil }
        return look == .solid ? (p.dpadBorder ?? line) : p.dpadBorderC
    }
}

/// The resting shadow, the pressed glow, or Bold's halo.
private struct PadShadow: ViewModifier {
    let skin: PadSkin
    let pressed: Bool
    var halo = true

    func body(content: Content) -> some View {
        if skin.seeThrough {
            let h = halo ? skin.halo : nil
            content
                .shadow(color: h ?? .clear, radius: h == nil ? 0 : 1)
                .shadow(color: h ?? .clear, radius: h == nil ? 0 : 1)
                .shadow(color: pressed ? skin.p.accentGlow : .clear, radius: pressed ? 6 : 0)
        } else {
            content
                .shadow(color: pressed ? skin.p.accentGlow : .black.opacity(0.4),
                        radius: pressed ? 8 : 2.5, y: pressed ? 0 : 2)
        }
    }
}

private func gradient(_ c: [Color]) -> LinearGradient {
    LinearGradient(colors: c, startPoint: .top, endPoint: .bottom)
}

// MARK: - The controls

/// Every pad, drawn at its frame. Hit testing is off: TouchRouter takes
/// the touches.
struct TouchControls: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.palette) var palette
    @ObservedObject var state = TouchPadState.shared
    let frames: ControlFrames
    let geometry: PlayGeometry
    @State private var shown = false

    private var skin: PadSkin {
        let look: PadLook
        if geometry.mode == .phoneLandscape {
            switch settings.landscapeButtons {
            case .outline: look = .outline
            case .bold: look = .bold
            case .solid: look = .solid
            }
        } else {
            look = .normal
        }
        return PadSkin(p: palette, look: look)
    }

    var body: some View {
        let skin = skin
        let f = frames
        ZStack(alignment: .topLeading) {
            if settings.controlStyle == .joystick {
                JoystickView(skin: skin, state: state)
                    .frame(width: f.joyBase.width, height: f.joyBase.height)
                    .offset(x: f.joyBase.minX, y: f.joyBase.minY)
            } else {
                DPadView(skin: skin, lit: state.lit)
                    .frame(width: f.dpad.width, height: f.dpad.height)
                    .offset(x: f.dpad.minX, y: f.dpad.minY)
            }
            FaceButton(label: "A", skin: skin, pressed: state.lit.contains(4))
                .frame(width: f.a.width, height: f.a.height)
                .offset(x: f.a.minX, y: f.a.minY)
            FaceButton(label: "B", skin: skin, pressed: state.lit.contains(5))
                .frame(width: f.b.width, height: f.b.height)
                .offset(x: f.b.minX, y: f.b.minY)
            if !f.l.isNull {
                ShoulderKey(label: "L", skin: skin, pressed: state.lit.contains(8))
                    .frame(width: f.l.width, height: f.l.height)
                    .offset(x: f.l.minX, y: f.l.minY)
                ShoulderKey(label: "R", skin: skin, pressed: state.lit.contains(9))
                    .frame(width: f.r.width, height: f.r.height)
                    .offset(x: f.r.minX, y: f.r.minY)
            }
            PillKey(label: "Select", font: geometry.pillFont, skin: skin, pressed: state.lit.contains(6))
                .frame(width: f.select.width, height: f.select.height)
                .offset(x: f.select.minX, y: f.select.minY)
            PillKey(label: "Start", font: geometry.pillFont, skin: skin, pressed: state.lit.contains(7))
                .frame(width: f.start.width, height: f.start.height)
                .offset(x: f.start.minX, y: f.start.minY)
        }
        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
        // Opening or resuming a game: the controls rise a little into place
        // (web controls-in, 0.42 s).
        .offset(y: shown ? 0 : 28)
        .opacity(shown ? 1 : 0)
        .onAppear {
            withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.42).delay(0.08)) { shown = true }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The d-pad: four arms and the middle, a lit arm per held direction. The
/// see-through looks draw chevrons on the arms and drop the bar lines.
struct DPadView: View {
    let skin: PadSkin
    let lit: Set<Int>

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let c = s / 3
            let lw = skin.borderWidth(.dpad)
            ZStack(alignment: .topLeading) {
                // The middle cell, under the arms' edges.
                if let fill = skin.fill(.dpad, pressed: false) {
                    Rectangle()
                        .fill(LinearGradient(colors: fill, startPoint: UnitPoint(x: 0.5, y: 1 / 3),
                                             endPoint: UnitPoint(x: 0.5, y: 2 / 3)))
                        .frame(width: c, height: c)
                        .offset(x: c, y: c)
                    if !skin.seeThrough {
                        Circle()
                            .fill(Color.black.opacity(0.25))
                            .overlay(Circle().stroke(Color.black.opacity(0.35), lineWidth: 1).blur(radius: 1).clipShape(Circle()))
                            .frame(width: c * 0.56, height: c * 0.56)
                            .offset(x: c * 1.22, y: c * 1.22)
                    }
                }
                if let bar = skin.barLine {
                    bar.frame(width: c, height: lw).offset(x: c, y: c)
                    bar.frame(width: c, height: lw).offset(x: c, y: 2 * c - lw)
                }
                ForEach(0..<4, id: \.self) { id in
                    arm(id, size: s, lineWidth: lw)
                }
            }
            .modifier(PadShadow(skin: skin, pressed: false))
        }
    }

    /// Up is drawn in place; the other arms are it turned about the middle.
    private static let turns: [Double] = [0, .pi, -.pi / 2, .pi / 2]   // up, down, left, right
    /// Each arm's cell as unit-square y range, for its own top-to-bottom
    /// gradient (web: each cell has its own background).
    private static let cellY: [(CGFloat, CGFloat)] = [(0, 1 / 3), (2 / 3, 1), (1 / 3, 2 / 3), (1 / 3, 2 / 3)]

    @ViewBuilder
    private func arm(_ id: Int, size s: CGFloat, lineWidth lw: CGFloat) -> some View {
        let pressed = lit.contains(id)
        let turn = Self.turns[id]
        let (y0, y1) = Self.cellY[id]
        ZStack {
            if let fill = skin.fill(.dpad, pressed: pressed) {
                ArmShape(turn: turn, inset: 0, closed: true)
                    .fill(LinearGradient(colors: fill, startPoint: UnitPoint(x: 0.5, y: y0),
                                         endPoint: UnitPoint(x: 0.5, y: y1)))
            }
            ArmShape(turn: turn, inset: lw / 2, closed: false)
                .stroke(skin.border(.dpad, pressed: pressed), style: StrokeStyle(lineWidth: lw, lineJoin: .round))
            if skin.seeThrough {
                Chevron(turn: turn)
                    .stroke(skin.label(.dpad, pressed: pressed),
                            style: StrokeStyle(lineWidth: s / 3 * 0.36 * 2.6 / 24, lineCap: .round, lineJoin: .round))
            }
        }
        .shadow(color: pressed ? skin.p.accentGlow : .clear, radius: pressed ? 7 : 0)
    }
}

/// One d-pad arm in the d-pad's square: the up arm turned by `turn` about
/// the middle. `closed: false` leaves the side that meets the middle open
/// (the stroke); `inset` keeps the stroke inside the cell like a CSS border.
struct ArmShape: Shape {
    let turn: Double
    let inset: CGFloat
    let closed: Bool

    func path(in rect: CGRect) -> Path {
        let s = rect.width, c = s / 3
        let r = min(9, c / 2)
        let x0 = c + inset, x1 = 2 * c - inset, y0 = inset, y1 = c
        var p = Path()
        p.move(to: CGPoint(x: x0, y: y1))
        p.addArc(tangent1End: CGPoint(x: x0, y: y0), tangent2End: CGPoint(x: x1, y: y0), radius: r)
        p.addArc(tangent1End: CGPoint(x: x1, y: y0), tangent2End: CGPoint(x: x1, y: y1), radius: r)
        p.addLine(to: CGPoint(x: x1, y: y1))
        if closed { p.closeSubpath() }
        let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: turn)
            .translatedBy(x: -s / 2, y: -s / 2)
        return p.applying(t)
    }
}

/// The see-through looks' arrow on an arm: 36% of the cell (web --dpad-arrow).
struct Chevron: Shape {
    let turn: Double

    func path(in rect: CGRect) -> Path {
        let s = rect.width, c = s / 3
        let box = c * 0.36, u = box / 24
        let ox = c + (c - box) / 2, oy = (c - box) / 2
        var p = Path()
        p.move(to: CGPoint(x: ox + 6 * u, y: oy + 15 * u))
        p.addLine(to: CGPoint(x: ox + 12 * u, y: oy + 9 * u))
        p.addLine(to: CGPoint(x: ox + 18 * u, y: oy + 15 * u))
        let t = CGAffineTransform(translationX: rect.midX, y: rect.midY)
            .rotated(by: turn)
            .translatedBy(x: -s / 2, y: -s / 2)
        return p.applying(t)
    }
}

struct FaceButton: View {
    let label: String
    let skin: PadSkin
    let pressed: Bool

    var body: some View {
        GeometryReader { geo in
            let d = geo.size.width
            ZStack {
                if let fill = skin.fill(.face, pressed: pressed) {
                    Circle().fill(gradient(fill))
                    if !pressed {
                        Circle().trim(from: 0.6, to: 0.9).stroke(skin.insetHi, lineWidth: 1).padding(1.5)
                    }
                }
                Circle().strokeBorder(skin.border(.face, pressed: pressed), lineWidth: skin.borderWidth(.face))
                Text(label)
                    .font(.system(size: d * 0.32, weight: .semibold))
                    .foregroundColor(skin.label(.face, pressed: pressed))
            }
            .modifier(PadShadow(skin: skin, pressed: pressed))
        }
    }
}

/// web .pad-shoulder: 10pt top corners, 6pt bottom.
struct ShoulderKey: View {
    let label: String
    let skin: PadSkin
    let pressed: Bool

    var body: some View {
        let shape = CornerRect(top: 10, bottom: 6)
        ZStack {
            if let fill = skin.fill(.pad, pressed: pressed) {
                shape.fill(gradient(fill))
            }
            shape.inset(by: skin.borderWidth(.pad) / 2)
                .stroke(skin.border(.pad, pressed: pressed), lineWidth: skin.borderWidth(.pad))
            Text(label)
                .font(.system(size: 15, weight: .semibold))
                .tracking(1.8)
                .foregroundColor(skin.label(.pad, pressed: pressed))
        }
        .modifier(PadShadow(skin: skin, pressed: pressed))
    }
}

struct PillKey: View {
    let label: String
    let font: CGFloat
    let skin: PadSkin
    let pressed: Bool

    var body: some View {
        ZStack {
            if let fill = skin.fill(.pill, pressed: pressed) {
                Capsule().fill(gradient(fill))
            }
            Capsule().strokeBorder(skin.border(.pill, pressed: pressed), lineWidth: skin.borderWidth(.pill))
            Text(label.uppercased())
                .font(.system(size: font, weight: .semibold))
                .tracking(font * 0.14)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .foregroundColor(skin.label(.pill, pressed: pressed))
        }
        .modifier(PadShadow(skin: skin, pressed: pressed))
    }
}

/// The joystick (web #joystick-base / -knob / -rim): a ringed base with a
/// recessed well, a knob that follows the thumb, and an accent arc on the
/// rim pointing at the direction being sent.
struct JoystickView: View {
    let skin: PadSkin
    @ObservedObject var state: TouchPadState

    var body: some View {
        GeometryReader { geo in
            let s = geo.size.width
            let active = state.joyRim != nil
            ZStack {
                ZStack {
                    if let fill = skin.fill(.pad, pressed: false) {
                        Circle().fill(gradient(fill))
                        Circle().fill(Color.black.opacity(0.25)).padding(s * 0.18)
                    }
                    Circle().strokeBorder(skin.border(.pad, pressed: false), lineWidth: skin.borderWidth(.pad))
                    if let angle = state.joyRim {
                        Circle()
                            .trim(from: 0.625, to: 0.875)
                            .stroke(skin.p.accent.opacity(0.85), style: StrokeStyle(lineWidth: 3, lineCap: .butt))
                            .padding(skin.look == .bold ? -0.5 : 0.5)
                            .rotationEffect(angle)
                            .shadow(color: skin.p.accentGlow, radius: 5)
                    }
                }
                .modifier(PadShadow(skin: skin, pressed: false))
                ZStack {
                    if let fill = skin.fill(.pad, pressed: active) {
                        Circle().fill(gradient(fill))
                    }
                    Circle().strokeBorder(skin.border(.pad, pressed: active), lineWidth: skin.borderWidth(.pad))
                }
                .frame(width: s * 0.44, height: s * 0.44)
                .modifier(PadShadow(skin: skin, pressed: active, halo: false))
                .offset(state.joyKnob)
            }
            .offset(state.joyBase)
        }
    }
}

/// A rectangle with its own top and bottom corner radii.
struct CornerRect: InsettableShape {
    var top: CGFloat
    var bottom: CGFloat
    var insetAmount: CGFloat = 0

    func path(in rect: CGRect) -> Path {
        let r = rect.insetBy(dx: insetAmount, dy: insetAmount)
        var p = Path()
        p.move(to: CGPoint(x: r.minX + top, y: r.minY))
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.maxY), radius: top)
        p.addArc(tangent1End: CGPoint(x: r.maxX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.maxY), radius: bottom)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.maxY), tangent2End: CGPoint(x: r.minX, y: r.minY), radius: bottom)
        p.addArc(tangent1End: CGPoint(x: r.minX, y: r.minY), tangent2End: CGPoint(x: r.maxX, y: r.minY), radius: top)
        p.closeSubpath()
        return p
    }

    func inset(by amount: CGFloat) -> CornerRect {
        var s = self
        s.insetAmount += amount
        return s
    }
}

// MARK: - Touch routing

/// Fills the play screen; claims only touches that start on a control.
struct TouchRouter: UIViewRepresentable {
    @EnvironmentObject var settings: Settings
    let frames: ControlFrames
    /// Off while the in-game menu's scrim is up.
    let enabled: Bool
    /// Phone landscape with the bar down: the bar owns the strip above this.
    let blockedTop: CGFloat

    func makeUIView(context: Context) -> TouchRouterView {
        let v = TouchRouterView()
        TouchRouterView.current = v
        return v
    }

    func updateUIView(_ v: TouchRouterView, context: Context) {
        TouchRouterView.current = v
        let joystick = settings.controlStyle == .joystick
        if v.frames != frames || v.joystick != joystick || (!enabled && v.enabled) { v.releaseAll() }
        v.frames = frames
        v.joystick = joystick
        v.floating = settings.joystickMode == .floating
        v.enabled = enabled
        v.blockedTop = blockedTop
    }

    static func dismantleUIView(_ v: TouchRouterView, coordinator: ()) {
        v.releaseAll()
        if TouchRouterView.current === v { TouchRouterView.current = nil }
    }
}

final class TouchRouterView: UIView {
    /// The live router, so a layout change elsewhere can let go of
    /// everything it holds.
    static weak var current: TouchRouterView?

    var frames = ControlFrames()
    var joystick = false
    var floating = false
    var enabled = true
    var blockedTop: CGFloat = 0

    private let state = TouchPadState.shared
    private var buttonTouches: [UITouch: Int] = [:]
    private var dpadTouch: UITouch?
    private var dpadCell: Int?          // 0...8 without the middle (4), or nil
    private var joyTouch: UITouch?
    private var joyHome = CGPoint.zero
    private var joyR: CGFloat = 1
    private var joyCenter = CGPoint.zero
    private var joyBits: Set<Int> = []
    private var sent: Set<Int> = []

    /// Each d-pad cell's inputs, row by row; the middle has none.
    private static let cellInputs: [[Int]] = [[0, 2], [0], [0, 3], [2], [], [3], [1, 2], [1], [1, 3]]
    private static let buttonIds = [8, 9, 6, 7, 4, 5]   // shoulders and pills sit above the joystick region

    private static let joyDeadzone: CGFloat = 0.35   // radial, fraction of the base radius
    private static let joyAxial: CGFloat = 0.4       // per-axis threshold, as the controller stick
    private static let joyKnobTravel: CGFloat = 0.6  // knob-centre clamp, fraction of the radius

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .clear
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard enabled, point.y >= blockedTop else { return nil }
        if buttonAt(point) != nil { return self }
        if joystick ? frames.joyRegion.contains(point) : frames.dpad.contains(point) { return self }
        return nil
    }

    private func buttonAt(_ p: CGPoint) -> Int? {
        Self.buttonIds.first { frames.hitRect($0).contains(p) }
    }

    private func cellAt(_ p: CGPoint) -> Int? {
        let r = frames.dpad
        guard r.contains(p) else { return nil }
        let col = min(2, max(0, Int((p.x - r.minX) / (r.width / 3))))
        let row = min(2, max(0, Int((p.y - r.minY) / (r.height / 3))))
        let i = row * 3 + col
        return i == 4 ? nil : i
    }

    // MARK: touches

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        var tick = false
        for t in touches {
            let p = t.location(in: self)
            if let id = buttonAt(p) {
                buttonTouches[t] = id
            } else if joystick {
                if joyTouch == nil, frames.joyRegion.contains(p) { joyStart(t, at: p) }
            } else if dpadTouch == nil, frames.dpad.contains(p) {
                // One finger drives the d-pad; it may start on the middle.
                dpadTouch = t
                dpadCell = cellAt(p)
                if dpadCell != nil { tick = true }
            }
        }
        sync(tick: tick)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        var tick = false
        for t in touches {
            let p = t.location(in: self)
            if t === dpadTouch { tick = dpadMove(to: p) || tick }
            if t === joyTouch { tick = joyTrack(p) || tick }
        }
        sync(tick: tick)
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        end(touches)
    }

    private func end(_ touches: Set<UITouch>) {
        for t in touches {
            buttonTouches[t] = nil
            if t === dpadTouch { dpadTouch = nil; dpadCell = nil }
            if t === joyTouch { joyRelease() }
        }
        sync(tick: false)
    }

    /// Slide between directions; just past the pad's edge (22% of its
    /// width) the direction holds, as it does over the middle. Returns
    /// whether the direction changed to a new one.
    private func dpadMove(to p: CGPoint) -> Bool {
        let cell = cellAt(p)
        if cell == dpadCell { return false }
        if let cell {
            dpadCell = cell
            return true
        }
        let onOther = buttonAt(p) != nil
        let margin = frames.dpad.width * 0.22
        if dpadCell != nil, !onOther, frames.dpad.insetBy(dx: -margin, dy: -margin).contains(p) {
            return false
        }
        dpadCell = nil
        return false
    }

    // MARK: joystick

    private func joyStart(_ t: UITouch, at p: CGPoint) {
        joyTouch = t
        joyHome = CGPoint(x: frames.joyBase.midX, y: frames.joyBase.midY)
        joyR = frames.joyBase.width / 2
        joyCenter = floating ? clampToRegion(p) : joyHome
        _ = joyTrack(p)
    }

    /// Floating mode: the base spawns under the thumb and is dragged along
    /// past the rim, never out of the touch region.
    private func clampToRegion(_ c: CGPoint) -> CGPoint {
        let b = frames.joyRegion.insetBy(dx: joyR, dy: joyR)
        let x = b.width < 0 ? frames.joyRegion.midX : min(b.maxX, max(b.minX, c.x))
        let y = b.height < 0 ? frames.joyRegion.midY : min(b.maxY, max(b.minY, c.y))
        return CGPoint(x: x, y: y)
    }

    private func joyTrack(_ p: CGPoint) -> Bool {
        var dx = p.x - joyCenter.x, dy = p.y - joyCenter.y
        var mag = hypot(dx, dy)
        if floating && mag > joyR {
            let pull = (mag - joyR) / mag
            joyCenter = clampToRegion(CGPoint(x: joyCenter.x + dx * pull, y: joyCenter.y + dy * pull))
            dx = p.x - joyCenter.x; dy = p.y - joyCenter.y
            mag = hypot(dx, dy)
        }
        var want: Set<Int> = []
        if mag > joyR * Self.joyDeadzone {
            let ux = dx / mag, uy = dy / mag
            if uy < -Self.joyAxial { want.insert(0) }
            if uy > Self.joyAxial { want.insert(1) }
            if ux < -Self.joyAxial { want.insert(2) }
            if ux > Self.joyAxial { want.insert(3) }
        }
        state.joyBase = CGSize(width: joyCenter.x - joyHome.x, height: joyCenter.y - joyHome.y)
        let lim = joyR * Self.joyKnobTravel
        let k = mag > lim ? lim / mag : 1
        state.joyKnob = CGSize(width: dx * k, height: dy * k)
        let changed = want != joyBits
        joyBits = want
        if want.isEmpty {
            state.joyRim = nil
        } else {
            // 0 = up, clockwise.
            let rx: Double = (want.contains(3) ? 1 : 0) - (want.contains(2) ? 1 : 0)
            let ry: Double = (want.contains(1) ? 1 : 0) - (want.contains(0) ? 1 : 0)
            state.joyRim = .radians(atan2(rx, -ry))
        }
        return changed && !want.isEmpty
    }

    /// Let go and snap home.
    private func joyRelease() {
        joyTouch = nil
        joyBits = []
        state.joyRim = nil
        withAnimation(.easeOut(duration: 0.16)) {
            state.joyBase = .zero
            state.joyKnob = .zero
        }
    }

    // MARK: output

    /// Send what changed; light the pads; tick the haptic on each press and
    /// direction change.
    private func sync(tick: Bool) {
        var want = Set(buttonTouches.values)
        if let c = dpadCell { want.formUnion(Self.cellInputs[c]) }
        want.formUnion(joyBits)
        let session = GameSession.shared
        let pressed = want.subtracting(sent)
        for id in pressed { session.setInput(id, true, source: "touch") }
        for id in sent.subtracting(want) { session.setInput(id, false, source: "touch") }
        if tick || !pressed.isEmpty { Peripherals.shared.tap() }
        sent = want
        if state.lit != want { state.lit = want }
    }

    func releaseAll() {
        buttonTouches = [:]
        dpadTouch = nil
        dpadCell = nil
        if joyTouch != nil { joyRelease() }
        joyBits = []
        sync(tick: false)
    }
}
