import SwiftUI
import UIKit

/// The play screen (web body.running): the top bar, the game on the stage,
/// and the touch controls, arranged per device and orientation by
/// PlayLayout. The in-game menu drops down from the bar's hamburger.
struct PlayView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        PlayLayout(stage: GameStage(), bar: TopBar())
            .overlay(alignment: .topLeading) {
                if model.menuOpen {
                    GameMenu()
                }
            }
            .overlay { ClipProgressView() }
            .statusBarHidden(true)
            .persistentSystemOverlays(.hidden)
    }
}

// MARK: - The stage

/// The game picture on the stage: contain-fit (whole multiples with integer
/// scaling), the ambient glow behind it, pinch zoom, the rumble shake, and in
/// phone landscape a tap on the picture shows and hides the top bar.
struct GameStage: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: GameSession
    @EnvironmentObject var settings: Settings
    @Environment(\.palette) var palette
    @Environment(\.verticalSizeClass) var vSize

    @State private var zoom: CGFloat = 1
    @State private var zoomBase: CGFloat = 1
    @State private var pan: CGSize = .zero
    @State private var panBase: CGSize = .zero
    @State private var lastGame: RomEntry?

    /// Phone landscape (web: coarse pointer, landscape, max-height 500).
    private var phoneLandscape: Bool { vSize == .compact }

    var body: some View {
        GeometryReader { geo in
            let size = pictureSize(in: geo.size)
            ZStack {
                (palette.chromeTransparent ? Color.clear : palette.stage)
                if settings.ambientGlow {
                    GlowView(box: size)
                        .frame(width: size.width, height: size.height)
                        .scaleEffect(1.45)
                        .opacity(0.8)
                        .allowsHitTesting(false)
                }
                GameScreenView()
                    .frame(width: size.width, height: size.height)
                    .modifier(RumbleShake(active: session.rumbling))
                    .scaleEffect(zoom)
                    .offset(pan)
                    .accessibilityLabel("Game screen")
                if settings.inputDisplay {
                    InputOverlay()
                        .frame(width: size.width, height: size.height, alignment: .bottomLeading)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            // OLED black: the chrome is see-through and the glow bleeds
            // behind it (web: the stage stops clipping).
            .clipped(antialiased: false, if: !palette.chromeTransparent)
            .contentShape(Rectangle())
            .gesture(magnify(geo.size, picture: size))
            .simultaneousGesture(zoom > 1 ? panGesture(geo.size, picture: size) : nil)
            .gesture(taps(geo.size, picture: size))
            .onChange(of: session.game) { g in
                if g != lastGame { lastGame = g; resetZoom(animated: false) }
            }
            .onChange(of: model.screen) { s in if s == .home { resetZoom(animated: false) } }
        }
    }

    /// The picture's box: contain-fit of the presented size (an SGB border
    /// makes it 256x224), in whole device-pixel multiples with integer
    /// scaling.
    private func pictureSize(in box: CGSize) -> CGSize {
        let w = max(session.outSize.width, 1), h = max(session.outSize.height, 1)
        let fit = min(box.width / w, box.height / h)
        guard fit > 0 else { return .zero }
        let px = UIScreen.main.scale
        // web: whole multiples of the native size in points with integer
        // scaling, else a plain contain-fit (the edges land on device pixels).
        let scale = settings.integerScale && fit >= 1 ? floor(fit) : fit
        return CGSize(width: (w * scale * px).rounded(.down) / px,
                      height: (h * scale * px).rounded(.down) / px)
    }

    private func clampPan(_ p: CGSize, zoom z: CGFloat, box: CGSize, picture: CGSize) -> CGSize {
        // Inside the stage when smaller, covering it when larger (web clamp).
        let pw = picture.width * z, ph = picture.height * z
        let mx = abs(pw - box.width) / 2, my = abs(ph - box.height) / 2
        return CGSize(width: min(mx, max(-mx, p.width)), height: min(my, max(-my, p.height)))
    }

    private func magnify(_ box: CGSize, picture: CGSize) -> some Gesture {
        MagnificationGesture()
            .onChanged { v in
                zoom = min(6, max(1, zoomBase * v))
                pan = clampPan(pan, zoom: zoom, box: box, picture: picture)
            }
            .onEnded { _ in
                zoomBase = zoom
                panBase = pan
                if zoom <= 1.01 { resetZoom(animated: true) }
            }
    }

    private func panGesture(_ box: CGSize, picture: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 4)
            .onChanged { v in
                pan = clampPan(CGSize(width: panBase.width + v.translation.width,
                                      height: panBase.height + v.translation.height),
                               zoom: zoom, box: box, picture: picture)
            }
            .onEnded { _ in panBase = pan }
    }

    /// Zoomed: a double tap resets (the single tap waits it out). Phone
    /// landscape: a single tap clear of every control toggles the top bar.
    private func taps(_ box: CGSize, picture: CGSize) -> some Gesture {
        let single = SpatialTapGesture(count: 1, coordinateSpace: .global)
            .onEnded { v in toggleBar(at: v.location) }
        let double = TapGesture(count: 2).onEnded { resetZoom(animated: true) }
        return double.exclusively(before: single)
    }

    private func toggleBar(at p: CGPoint) {
        guard phoneLandscape, model.session.game != nil else { return }
        let clear = PadGeometry.shared.rects.allSatisfy { !$0.insetBy(dx: -20, dy: -20).contains(p) }
        guard clear else { return }
        withAnimation(.easeOut(duration: 0.2)) { model.topbarOpen.toggle() }
        BarTapHint.markUsed()
    }

    private func resetZoom(animated: Bool) {
        let apply = { zoom = 1; zoomBase = 1; pan = .zero; panBase = .zero }
        if animated { withAnimation(.easeOut(duration: 0.25), apply) } else { apply() }
    }
}

/// The one-time "Tap the picture to show the bar" toast for phone landscape.
enum BarTapHint {
    private static let key = "dingbat_bar_tap_hint"
    static func showIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        AppModel.shared.toast("Tap the picture to show the bar", duration: 4)
    }
    static func markUsed() { UserDefaults.standard.set(true, forKey: key) }
}

/// The rumble motor shakes the picture (web body.rumbling).
struct RumbleShake: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active {
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate
                content.offset(x: CGFloat(sin(t * 95)) * 1.6, y: CGFloat(cos(t * 83)) * 1.2)
            }
        } else {
            content
        }
    }
}

/// Ambient glow: a coarse sample of the picture, saturated x1.5, blended
/// over the last at 0.3 and blurred behind the screen (web glow composer),
/// sampled ~10 times a second.
private extension View {
    @ViewBuilder func clipped(antialiased: Bool, if on: Bool) -> some View {
        if on { clipped(antialiased: antialiased) } else { self }
    }
}

struct GlowView: View {
    /// The picture's box, in points (the glow is composed for it).
    let box: CGSize
    @EnvironmentObject var session: GameSession
    @EnvironmentObject var settings: Settings
    @State private var image: CGImage?
    @State private var fresh = true
    @State private var composer = GlowComposer(sw: 24, sh: 16)

    var body: some View {
        Group {
            if let image {
                // Stretched bilinearly, as the browser stretches the canvas.
                Image(decorative: image, scale: 1)
                    .resizable()
                    .interpolation(.medium)
            } else {
                Color.clear
            }
        }
        // 10 Hz, for as long as the view lives (a timer publisher stored on
        // the struct is rebuilt with it and never fires).
        .task {
            while !Task.isCancelled {
                sample()
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        .onChange(of: session.game) { _ in fresh = true }
        .onChange(of: settings.ambientGlow) { _ in fresh = true }
    }

    /// web updateGlow: the core samples (it owns the LUT and the SGB
    /// border); a monochrome Game Boy's chosen shade palette is passed in.
    private func sample() {
        guard session.game != nil else { return }
        composer.layout(width: box.width, height: box.height)
        func abgr(_ c: UInt32) -> UInt32 {
            0xFF00_0000 | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)
        }
        let mono = dingbat_is_gb() != 0 && dingbat_is_cgb() == 0 && dingbat_sgb_active() == 0
        let pal = mono ? settings.dmgPalette : nil
        let p = pal.map { $0.map(abgr) } ?? [0, 0, 0, 0]
        guard let rgba = dingbat_glow_sample(Int32(composer.sw), Int32(composer.sh), pal == nil ? 0 : 1,
                                             p[0], p[1], p[2], p[3]) else { return }
        if let img = composer.compose(rgba, fresh: fresh) { image = img }
        fresh = false
    }
}

/// "Show inputs on screen": the held buttons, bottom-left of the picture.
struct InputOverlay: View {
    @EnvironmentObject var session: GameSession
    private static let names = ["↑", "↓", "←", "→", "A", "B", "SELECT", "START", "L", "R"]

    var body: some View {
        HStack(spacing: 4) {
            ForEach(session.held.sorted(), id: \.self) { id in
                Text(Self.names[id])
                    .font(.system(size: 11, weight: .bold, design: .monospaced))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.black.opacity(0.55)))
            }
        }
        .padding(8)
    }
}

// MARK: - Top bar

/// The in-game top bar (web #topbar while running), in markup order.
struct TopBar: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: GameSession
    @EnvironmentObject var settings: Settings
    @Environment(\.palette) var palette
    @Environment(\.horizontalSizeClass) var hSize
    @ObservedObject private var link = NetLink.shared

    private var wide: Bool { hSize == .regular }

    var body: some View {
        HStack(spacing: 6) {
            if wide {
                Button { model.showMainMenu() } label: { BarBrand() }
                    .accessibilityLabel("Main Menu")
            }
            BarIconButton(system: "line.3.horizontal", label: "Menu", active: model.menuOpen,
                          dot: model.newPrints) {
                model.toggleMenu()
            }
            PlaybackCluster()
            if session.tiltKind > 0 {
                BarIconButton(system: "scope", label: "Recenter tilt") {
                    Peripherals.shared.recenterTilt()
                }
            }
            if session.hasCamera {
                BarIconButton(system: Peripherals.shared.cameraOn ? "arrow.triangle.2.circlepath.camera" : "camera",
                              label: "Camera") {
                    Peripherals.shared.cameraButton()
                }
            }
            Spacer(minLength: 2)
            if link.linked { LinkDisconnectPill(wide: wide) }
            SyncIndicator()
            StatusReadout()
            if settings.channelMutes != 0 {
                Button {
                    model.openSheet(.settings(section: "audio"))
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "speaker.slash")
                        Text(wide ? "\(settings.channelMutes.nonzeroBitCount) off" : "\(settings.channelMutes.nonzeroBitCount)")
                    }
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundColor(palette.accent)
                    .padding(.horizontal, 7)
                    .frame(height: 26)
                    .background(Capsule().fill(palette.accentGlow.opacity(0.4)))
                }
                .accessibilityLabel("Muted channels")
            }
            if settings.mp2kHle && session.mp2kAvailable && !link.linked {
                BarIconButton(system: "music.note", label: "Enhanced music",
                              active: session.hleActive && !session.hleSessionOff) {
                    session.hleSessionOff.toggle()
                    session.applyHle()
                    model.toast(session.hleSessionOff ? "Enhanced music off for this game"
                                                      : "Enhanced music on")
                }
            }
            VolumeControl(showSlider: wide)
        }
        .padding(.horizontal, 10)
        .frame(height: 52)
        .background(
            Group {
                if palette.chromeTransparent && !(model.topbarOpen) {
                    Color.clear
                } else {
                    LinearGradient(colors: [palette.topbarTop, palette.topbarBottom],
                                   startPoint: .top, endPoint: .bottom)
                }
            }
        )
        .overlay(Rectangle().fill(palette.frameLine).frame(height: 1), alignment: .bottom)
    }
}

/// web #rb-disconnect: linked, a pill in the bar; two taps end the session.
struct LinkDisconnectPill: View {
    let wide: Bool
    @Environment(\.palette) var palette
    @State private var armed = false

    var body: some View {
        Button {
            if armed {
                armed = false
                NetLink.shared.disconnect()
            } else {
                armed = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { armed = false }
            }
        } label: {
            HStack(spacing: 5) {
                if wide && !armed { Image(systemName: "cable.connector") }
                Text(armed ? "Are you sure?" : wide ? "Disconnect Link Cable" : "Disconnect")
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(armed ? .white : palette.accent)
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Capsule().fill(armed ? palette.danger : palette.accentGlow.opacity(0.4)))
        }
        .accessibilityLabel("Disconnect link cable")
    }
}

struct BarBrand: View {
    @Environment(\.palette) var palette
    var body: some View {
        HStack(spacing: 6) {
            Image("Logo")
                .resizable()
                .frame(width: 22, height: 22)
            Text("dingbat")
                .font(.system(size: 16, weight: .bold))
                .foregroundColor(palette.chromeInk)
        }
        .padding(.trailing, 6)
    }
}

/// A top-bar icon button (web .icon-btn), shell-skinned on device themes.
struct BarIconButton: View {
    @Environment(\.palette) var palette
    let system: String
    var label: String
    var active = false
    var dot = false
    var width: CGFloat = 34
    let action: () -> Void

    var body: some View {
        button.padFocus("bar:" + label, radius: 9, press: action)
    }

    private var button: some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 15, weight: .semibold))
                .foregroundColor(active ? palette.accent : palette.chromeInk)
                .frame(width: width, height: 34)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(active
                              ? AnyShapeStyle(LinearGradient(colors: [palette.accentTintTop, palette.btnActiveBottom],
                                                             startPoint: .top, endPoint: .bottom))
                              : AnyShapeStyle(LinearGradient(colors: [palette.chromeBtnTop, palette.chromeBtnBottom],
                                                             startPoint: .top, endPoint: .bottom)))
                )
                .overlay(RoundedRectangle(cornerRadius: 9)
                    .stroke(active ? palette.accent.opacity(0.5) : palette.chromeBtnBorder, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if dot {
                        Circle().fill(palette.accent).frame(width: 7, height: 7).offset(x: -4, y: 4)
                    }
                }
        }
        .accessibilityLabel(label)
    }
}

/// Reset · Rewind · Pause · (paused: Step | running: 2x · Fast forward).
struct PlaybackCluster: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: GameSession
    @EnvironmentObject var settings: Settings
    @Environment(\.palette) var palette
    @Environment(\.horizontalSizeClass) var hSize

    @State private var lastRewindTap: Date = .distantPast
    @State private var rewindDown: Date?
    @State private var stepTimer: Timer?
    // Held states that SwiftUI resets when the touch ends OR is cancelled
    // (Control Centre, the app going inactive), so neither button can stick.
    @GestureState private var rewindHeld = false
    @GestureState private var stepHeld = false

    @ObservedObject private var link = NetLink.shared

    var body: some View {
        let w: CGFloat = hSize == .regular ? 34 : 30
        HStack(spacing: hSize == .regular ? 6 : 2) {
            if !link.linked {
                BarIconButton(system: "arrow.counterclockwise", label: "Reset", width: w) { session.reset() }
            }
            if settings.rewind && !link.linked {
                rewindButton(width: w)
            }
            BarIconButton(system: session.paused ? "play.fill" : "pause.fill",
                          label: "Pause / Resume", active: session.paused, width: w) {
                model.closeMenu()
                session.togglePause()
            }
            if session.paused && !link.linked {
                stepButton(width: w)
            } else if !session.paused {
                Button { session.toggleDouble() } label: {
                    SpeedGlyph(count: 2, active: session.speed == .double, width: w)
                }
                .accessibilityLabel("2x Speed")
                if !link.linked {
                    Button { session.toggleFastForward() } label: {
                        SpeedGlyph(count: 3, active: session.speed == .fastForward, width: w)
                    }
                    .accessibilityLabel("Fast Forward")
                }
            }
        }
    }

    /// Hold to rewind; a quick double tap opens the scrubber (web: <=250 ms
    /// press, <=300 ms gap).
    private func rewindButton(width: CGFloat) -> some View {
        SpeedGlyph(count: 2, active: session.rewinding, width: width, backward: true)
            .gesture(DragGesture(minimumDistance: 0).updating($rewindHeld) { _, held, _ in held = true })
            .onChange(of: rewindHeld) { held in
                if held {
                    rewindDown = Date()
                    session.setRewinding(true)
                    return
                }
                session.setRewinding(false)
                let press = Date().timeIntervalSince(rewindDown ?? Date())
                rewindDown = nil
                guard press <= 0.25 else { lastRewindTap = .distantPast; return }
                if Date().timeIntervalSince(lastRewindTap) <= 0.3 + 0.25 {
                    lastRewindTap = .distantPast
                    model.openSheet(.rewind)
                } else {
                    lastRewindTap = Date()
                }
            }
            .accessibilityLabel("Rewind: hold to rewind, double-tap to pick a moment")
            .accessibilityAddTraits(.isButton)
    }

    /// Tap = one frame; hold 400 ms, then a frame every 100 ms.
    private func stepButton(width: CGFloat) -> some View {
        BarIconButtonLabel(system: "forward.frame.fill", width: width)
            .gesture(DragGesture(minimumDistance: 0).updating($stepHeld) { _, held, _ in held = true })
            .onChange(of: stepHeld) { held in
                stopStepping()
                guard held else { return }
                session.stepFrame()
                stepTimer = Timer.scheduledTimer(withTimeInterval: 0.4, repeats: false) { _ in
                    stepTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                        guard session.paused else { stopStepping(); return }
                        session.stepFrame()
                    }
                }
            }
            .onDisappear(perform: stopStepping)
            .accessibilityLabel("Step one frame")
            .accessibilityAddTraits(.isButton)
    }

    private func stopStepping() {
        stepTimer?.invalidate()
        stepTimer = nil
    }
}

struct BarIconButtonLabel: View {
    @Environment(\.palette) var palette
    let system: String
    var width: CGFloat = 34
    var body: some View {
        Image(systemName: system)
            .font(.system(size: 15, weight: .semibold))
            .foregroundColor(palette.chromeInk)
            .frame(width: width, height: 34)
            .background(RoundedRectangle(cornerRadius: 9)
                .fill(LinearGradient(colors: [palette.chromeBtnTop, palette.chromeBtnBottom],
                                     startPoint: .top, endPoint: .bottom)))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(palette.chromeBtnBorder, lineWidth: 1))
    }
}

/// The web's double (2x, rewind) and triple (fast-forward) triangles.
struct SpeedGlyph: View {
    @Environment(\.palette) var palette
    let count: Int
    let active: Bool
    var width: CGFloat = 34
    var backward = false

    var body: some View {
        Triangles(count: count)
            .fill(active ? palette.accent : palette.chromeInk)
            .frame(width: count == 3 ? 18 : 15, height: 11)
            .rotationEffect(backward ? .degrees(180) : .zero)
            .frame(width: width, height: 34)
            .background(
                RoundedRectangle(cornerRadius: 9)
                    .fill(active
                          ? AnyShapeStyle(LinearGradient(colors: [palette.accentTintTop, palette.btnActiveBottom],
                                                         startPoint: .top, endPoint: .bottom))
                          : AnyShapeStyle(LinearGradient(colors: [palette.chromeBtnTop, palette.chromeBtnBottom],
                                                         startPoint: .top, endPoint: .bottom)))
            )
            .overlay(RoundedRectangle(cornerRadius: 9)
                .stroke(active ? palette.accent.opacity(0.5) : palette.chromeBtnBorder, lineWidth: 1))
            .contentShape(Rectangle())
    }

    struct Triangles: Shape {
        let count: Int
        func path(in r: CGRect) -> Path {
            var p = Path()
            let w = r.width / CGFloat(count)
            for i in 0..<count {
                let x = r.minX + CGFloat(i) * w
                p.move(to: CGPoint(x: x, y: r.minY))
                p.addLine(to: CGPoint(x: x + w, y: r.midY))
                p.addLine(to: CGPoint(x: x, y: r.maxY))
                p.closeSubpath()
            }
            return p
        }
    }
}

/// fps when it is not what the mode expects, or SLEEPING.
struct StatusReadout: View {
    @EnvironmentObject var session: GameSession
    @Environment(\.palette) var palette
    @Environment(\.horizontalSizeClass) var hSize

    var body: some View {
        if session.sleeping {
            Text("SLEEPING")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundColor(palette.accent)
        } else if session.fpsUnusual {
            Text(hSize == .regular ? "\(session.fps) fps" : "\(session.fps)")
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(palette.statusInk)
                .fixedSize()
        }
    }
}

/// Mute button + slider (0–100, step 5). In game on phones the slider lives
/// in the menu instead.
struct VolumeControl: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.palette) var palette
    var showSlider: Bool
    var sliderWidth: CGFloat = 96

    var body: some View {
        HStack(spacing: 4) {
            BarIconButton(system: settings.muted || settings.volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill",
                          label: settings.muted ? "Unmute" : "Mute", active: settings.muted) {
                settings.muted.toggle()
            }
            if showSlider {
                VolumeSlider()
                    .frame(width: sliderWidth)
            }
        }
    }
}

/// The volume range (web .vol-range): a thin track and a small thumb, so it
/// fits the 64 pt phone home bar as well as the menu row.
struct VolumeSlider: View {
    @EnvironmentObject var settings: Settings
    @Environment(\.palette) var palette

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let f = CGFloat(settings.muted ? 0 : settings.volume) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(palette.surface3).frame(height: 4)
                Capsule().fill(palette.accent).frame(width: max(4, w * f), height: 4)
                Circle()
                    .fill(palette.accent2)
                    .overlay(Circle().stroke(palette.accentInk.opacity(0.35), lineWidth: 1))
                    .frame(width: 14, height: 14)
                    .offset(x: (w - 14) * f)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                let x = min(max(0, v.location.x - 7), w - 14) / max(1, w - 14)
                settings.volume = Int((x * 20).rounded()) * 5
                if settings.muted && settings.volume > 0 { settings.muted = false }
            })
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("Volume")
        .accessibilityValue("\(settings.volume)")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: settings.volume = min(100, settings.volume + 5)
            case .decrement: settings.volume = max(0, settings.volume - 5)
            @unknown default: break
            }
        }
    }
}

// MARK: - The in-game menu

/// The hamburger's dropdown (web #menu-dropdown), in order.
struct GameMenu: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var session: GameSession
    @EnvironmentObject var settings: Settings
    @Environment(\.palette) var palette
    @Environment(\.horizontalSizeClass) var hSize
    @State private var captureOpen = false
    @State private var disconnectArmed = false
    @ObservedObject private var clips = ClipExporter.shared
    @ObservedObject private var link = NetLink.shared

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Scrim: a tap outside closes the menu and resumes.
            Color.black.opacity(0.001)
                .ignoresSafeArea()
                .onTapGesture { model.closeMenu() }
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    if !link.linked { quickRow }
                    item("house", "Main Menu") { model.showMainMenu() }
                    sep
                    if !link.linked { soloItems }
                    if hSize != .regular {
                        HStack(spacing: 10) {
                            Image(systemName: "speaker.wave.2")
                                .foregroundColor(palette.textDim)
                            VolumeSlider()
                        }
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                    }
                    sep
                    linkItem
                    if !link.linked { item("star", "Cheats") { model.openSheet(.cheats) } }
                    item("gearshape", "Settings") { model.openSheet(.settings(section: nil)) }
                    sep
                    item("ladybug", "Report a Bug") { model.openSheet(.report) }
                }
                .padding(6)
            }
            .padScrollFollow(proxy)
            }
            .frame(width: 252)
            .frame(maxHeight: 520)
            .fixedSize(horizontal: false, vertical: true)
            .background(RoundedRectangle(cornerRadius: 14).fill(palette.surface1))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(palette.border2, lineWidth: 1))
            .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            .padding(.top, 56)
            .padding(.leading, hSize == .regular ? 120 : 10)
            .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .topLeading)))
        }
        .environment(\.padScope, "menu")
    }

    /// Link Cable, or while linked a two-step Disconnect (a mis-tap would
    /// end the session for both).
    @ViewBuilder private var linkItem: some View {
        if link.linked {
            item("cable.connector", disconnectArmed ? "Are you sure?" : "Disconnect",
                 tint: disconnectArmed ? palette.danger : nil) {
                if disconnectArmed {
                    disconnectArmed = false
                    model.closeMenu()
                    link.disconnect()
                } else {
                    disconnectArmed = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3.5) { disconnectArmed = false }
                }
            }
        } else {
            item("cable.connector", "Link Cable") { link.openSheet() }
        }
    }

    @ViewBuilder private var soloItems: some View {
        item("square.grid.2x2", "Save States") { model.openSheet(.states) }
        item("folder", "Manage Saves") { model.openSheet(.saves) }
        item("camera", "Capture", trailing: captureOpen ? "chevron.down" : "chevron.right",
             dot: model.newPrints) {
            withAnimation(.easeOut(duration: 0.15)) { captureOpen.toggle() }
        }
        if captureOpen {
            item("camera.viewfinder", "Screenshot", sub: true) { screenshot() }
            item(clips.recording ? "stop.circle.fill" : "record.circle",
                 clips.recording ? "Stop Recording" : "Record", sub: true,
                 tint: clips.recording ? palette.danger : nil) {
                model.closeMenu()
                clips.toggleRecording()
            }
            item("film.stack", "Clip that!", sub: true) { model.openSheet(.clip) }
            if !PrintStore.all().isEmpty {
                item("printer", "Printed Photos", sub: true, dot: model.newPrints) {
                    model.openSheet(.prints)
                }
            }
        }
    }

    private var quickRow: some View {
        HStack(spacing: 6) {
            quick("square.and.arrow.down", "Quick Save") {
                if session.saveState(slot: 0) { model.toast("State saved") }
                model.closeMenu()
            }
            quick("square.and.arrow.up", "Quick Load") {
                session.loadState(slot: 0)
                model.closeMenu()
            }
            if settings.rewind {
                quick("film", "Rewind to a Moment") { model.openSheet(.rewind) }
            }
            quick("tortoise", "Slow Motion", active: session.speed == .slow) {
                session.toggleSlowMotion()
            }
        }
        .padding(.bottom, 4)
    }

    private var sep: some View {
        Rectangle().fill(palette.border).frame(height: 1).padding(.vertical, 4)
    }

    private func quick(_ icon: String, _ label: String, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .foregroundColor(active ? palette.accent : palette.text)
                .frame(maxWidth: .infinity)
                .frame(height: 45)
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(active ? palette.accentTintTop : palette.surface2))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(active ? palette.accent.opacity(0.5) : palette.border, lineWidth: 1))
        }
        .accessibilityLabel(label)
        .padFocus("quick:" + label, radius: 10, press: action)
    }

    private func item(_ icon: String, _ label: String, trailing: String? = nil, sub: Bool = false,
                      dot: Bool = false, tint: Color? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 15))
                    .frame(width: 22)
                    .foregroundColor(tint ?? palette.textDim)
                Text(label)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(tint ?? palette.text)
                if dot { Circle().fill(palette.accent).frame(width: 6, height: 6) }
                Spacer()
                if let trailing {
                    Image(systemName: trailing)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(palette.textFaint)
                }
            }
            .padding(.leading, sub ? 26 : 12)
            .padding(.trailing, 12)
            .frame(height: 42)
            .contentShape(Rectangle())
        }
        .padFocus("menu:" + label, press: action)
    }

    /// The console's own picture at 4x (no filters, colour correction,
    /// palette or border), as the web's screenshot.
    private func screenshot() {
        guard let g = session.game, let fb = dingbat_framebuffer() else { return }
        let w = Int(dingbat_fb_width()), h = Int(dingbat_fb_height())
        guard let img = GameSession.bgr555Image(UnsafeRawPointer(fb), width: w, height: h) else { return }
        let size = CGSize(width: w * 4, height: h * 4)
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1
        let big = UIGraphicsImageRenderer(size: size, format: fmt).image { ctx in
            ctx.cgContext.interpolationQuality = .none
            img.draw(in: CGRect(origin: .zero, size: size))
        }
        guard let png = big.pngData() else { return }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(g.stem).png")
        try? png.write(to: url)
        Share.present([url])
    }
}

/// UIActivityViewController from SwiftUI (exports: screenshots, saves,
/// states, prints, bug reports).
enum Share {
    static func present(_ items: [Any]) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
              var top = scene.windows.first(where: { $0.isKeyWindow })?.rootViewController else { return }
        while let p = top.presentedViewController { top = p }
        let vc = UIActivityViewController(activityItems: items, applicationActivities: nil)
        vc.popoverPresentationController?.sourceView = top.view
        vc.popoverPresentationController?.sourceRect = CGRect(x: top.view.bounds.midX, y: 60, width: 1, height: 1)
        top.present(vc, animated: true)
    }
}
