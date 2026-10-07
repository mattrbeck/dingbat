import SwiftUI
import UIKit

/// Local 2P (web link mode, the per-tile 2P launcher behind `?2p`; here the
/// `-2p` launch argument shows it): two cores of one ROM on the emulated
/// cable, both screens on this one device. Player 1's screen is the usual
/// stage (filters, shader); player 2's is drawn beside or under it. Touch
/// drives the player whose screen was tapped last, a controller always
/// player 2. Player 1's battery is the game's save; player 2's its own
/// (rom-p2.sav, "save:<name>-p2"), a copy of player 1's the first time.
enum TwoPlayer {
    /// The 2P launcher on tiles (web ?2p).
    static let enabled = ProcessInfo.processInfo.arguments.contains("-2p")

    /// Player 2's picture views, redrawn after each linked frame.
    fileprivate static var screens = NSHashTable<P2LayerView>.weakObjects()

    static func refresh() {
        guard dingbat_link_active() != 0, !screens.allObjects.isEmpty, let px = dingbat_link_rgba(1) else { return }
        let w = Int(dingbat_fb_width()), h = Int(dingbat_fb_height())
        let data = Data(bytes: UnsafeRawPointer(px), count: w * h * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let img = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32,
                                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                provider: provider, decode: nil, shouldInterpolate: false,
                                intent: .defaultIntent) else { return }
        for v in screens.allObjects { v.layer.contents = img }
    }
}

/// The play screen's stage: one game, or in 2P both screens.
struct StageOrPair: View {
    @EnvironmentObject var session: GameSession
    @Environment(\.verticalSizeClass) var vSize

    var body: some View {
        if session.twoPlayer {
            let side = vSize == .compact
            let layout = side ? AnyLayout(HStackLayout(spacing: 6)) : AnyLayout(VStackLayout(spacing: 6))
            layout {
                screen(0) { GameStage() }
                screen(1) { P2Screen() }
            }
        } else {
            GameStage()
        }
    }

    /// One player's screen with its label; a tap gives it the touch controls.
    private func screen<C: View>(_ p: Int, @ViewBuilder _ content: () -> C) -> some View {
        content()
            .overlay(alignment: .topLeading) { PlayerLabel(player: p) }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { session.setFocusPlayer(p) })
    }
}

private struct PlayerLabel: View {
    let player: Int
    @EnvironmentObject var session: GameSession
    @Environment(\.palette) private var palette

    var body: some View {
        let on = session.focusPlayer == player
        Text(on ? "▶ P\(player + 1) · Touch" : player == 1 ? "P2 · Controller · tap for touch" : "P1 · Tap for touch")
            .font(.system(size: 11, weight: .semibold))
            .foregroundColor(on ? palette.accentInk : palette.textDim)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(Capsule().fill(on ? palette.accent : palette.surface2.opacity(0.85)))
            .padding(6)
            .allowsHitTesting(false)
    }
}

/// Player 2's screen, letterboxed like player 1's, nearest-neighbour.
private struct P2Screen: View {
    @EnvironmentObject var session: GameSession
    @Environment(\.palette) private var palette

    var body: some View {
        GeometryReader { geo in
            let gw: CGFloat = session.isGB ? 160 : 240, gh: CGFloat = session.isGB ? 144 : 160
            let s = min(geo.size.width / gw, geo.size.height / gh)
            P2LayerRepresentable()
                .frame(width: gw * s, height: gh * s)
                .frame(width: geo.size.width, height: geo.size.height)
        }
        // About the margin player 1's stage keeps, so the two match.
        .padding(.vertical, 18)
        .background(palette.chromeTransparent ? Color.clear : palette.stage)
    }
}

private struct P2LayerRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> P2LayerView {
        let v = P2LayerView()
        v.layer.magnificationFilter = .nearest
        v.layer.contentsGravity = .resize
        v.backgroundColor = .black
        TwoPlayer.screens.add(v)
        return v
    }

    func updateUIView(_ v: P2LayerView, context: Context) {}
}

final class P2LayerView: UIView {}
