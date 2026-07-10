import SwiftUI

/// The play screen: top bar (web UI's #top-bar), the game screen on the
/// stage, and the touch gamepad — stacked below the screen in portrait,
/// flanking it in landscape (matching the web layout breakpoints).
struct PlayView: View {
    let rom: RomEntry
    let onExit: () -> Void

    @StateObject private var session = EmulatorSession()
    @State private var pressed: Set<Int> = []
    @State private var padRects: [PadRect] = []

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                Theme.bg.ignoresSafeArea()
                if landscape {
                    landscapeLayout
                } else {
                    portraitLayout
                }
                TouchRoutingOverlay(
                    rects: padRects,
                    onInput: { id, down in session.setInput(id, down) },
                    onPressedChange: { pressed = $0 })
                if let toast = session.stateToast {
                    toastView(toast)
                }
                if session.loadFailed {
                    loadFailedView
                }
            }
        }
        .coordinateSpace(name: "pad")
        .onPreferenceChange(PadRectsKey.self) { padRects = $0 }
        .onAppear { session.start(rom: rom) }
        .onDisappear { session.stop() }
        .statusBarHidden(true)
    }

    // MARK: layouts

    private var portraitLayout: some View {
        VStack(spacing: 0) {
            topBar
            screen
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.stage)
            controlsPortrait
                .padding(.horizontal, 16)
                .padding(.top, 14)
                .padding(.bottom, 8)
                .background(
                    LinearGradient(colors: [Color(hex: 0x0E1119), Theme.bg],
                                   startPoint: .top, endPoint: .bottom))
        }
    }

    private var controlsPortrait: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                ShoulderButton(label: "L", id: 8, pressed: pressed)
                ShoulderButton(label: "R", id: 9, pressed: pressed)
            }
            HStack {
                DPadView(size: 174, pressed: pressed)
                Spacer()
                FaceButtonsView(buttonSize: 64, pressed: pressed)
            }
            HStack(spacing: 18) {
                PillButton(label: "Select", id: 6, pressed: pressed)
                PillButton(label: "Start", id: 7, pressed: pressed)
            }
        }
    }

    private var landscapeLayout: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 8) {
                VStack {
                    ShoulderButton(label: "L", id: 8, pressed: pressed)
                        .frame(width: 120)
                    Spacer()
                    DPadView(size: 150, pressed: pressed)
                    Spacer()
                    PillButton(label: "Select", id: 6, pressed: pressed)
                }
                .frame(width: 180)
                screen
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Theme.stage)
                VStack {
                    ShoulderButton(label: "R", id: 9, pressed: pressed)
                        .frame(width: 120)
                    Spacer()
                    FaceButtonsView(buttonSize: 58, pressed: pressed)
                    Spacer()
                    PillButton(label: "Start", id: 7, pressed: pressed)
                }
                .frame(width: 180)
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 6)
        }
    }

    // MARK: pieces

    private var topBar: some View {
        HStack(spacing: 6) {
            barButton("chevron.left") {
                onExit()
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(rom.name)
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundColor(Theme.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(session.sleeping ? "SLEEPING" : "\(session.fps) fps")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(session.sleeping ? Theme.accent : Theme.textFaint)
                    .fixedSize()
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            barButton("arrow.counterclockwise") { session.reset() }
            barButton(session.paused ? "play.fill" : "pause.fill",
                      active: session.paused) { session.togglePause() }
            barButton("forward.fill", active: session.fastForward) {
                session.toggleFastForward()
            }
            barButton("square.and.arrow.down") { session.saveState() }
            barButton("square.and.arrow.up") { session.loadState() }
            barButton(session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                      active: session.muted) { session.toggleMute() }
        }
        .padding(.horizontal, 12)
        .frame(height: 52)
        .background(Theme.surface1)
        .overlay(Rectangle().fill(Theme.border).frame(height: 1), alignment: .bottom)
    }

    private func barButton(_ systemName: String, active: Bool = false,
                           action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(active ? Theme.accent : Theme.textDim)
                .frame(width: 31, height: 34)
                .background(active ? Theme.accentGlow.opacity(0.35) : Color.clear)
                .cornerRadius(8)
        }
    }

    private var screen: some View {
        GeometryReader { geo in
            let fbw = CGFloat(max(Int(dingbat_fb_width()), 1))
            let fbh = CGFloat(max(Int(dingbat_fb_height()), 1))
            let rawScale = min(geo.size.width / fbw, geo.size.height / fbh)
            // Integer scaling in *device pixels* (like the web canvas) for
            // crisp, evenly-sized pixels while still filling the stage.
            let px = UIScreen.main.scale
            let scale = rawScale >= 1 ? floor(rawScale * px) / px : rawScale
            ZStack {
                if let image = session.image {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: fbw * scale, height: fbh * scale)
                } else {
                    Text("dingbat")
                        .font(.system(size: 15, design: .monospaced))
                        .foregroundColor(Theme.textFaint)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
    }

    private func toastView(_ message: String) -> some View {
        VStack {
            Text(message)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.accent)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(Theme.surface2)
                .cornerRadius(8)
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(Theme.border2, lineWidth: 1))
                .padding(.top, 64)
            Spacer()
        }
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private var loadFailedView: some View {
        VStack(spacing: 12) {
            Text("Failed to load ROM")
                .font(.system(size: 15, weight: .semibold, design: .monospaced))
                .foregroundColor(Theme.danger)
            Button("Back") { onExit() }
                .font(.system(size: 13, design: .monospaced))
                .foregroundColor(Theme.accent)
        }
        .padding(24)
        .background(Theme.surface1)
        .cornerRadius(11)
    }
}
