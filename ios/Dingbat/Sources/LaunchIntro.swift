// The opening: the launch screen's dingbat takes off from the middle of the
// screen and flies up to its place above the library, flapping on the way
// and settling as it lands, while the launch colour lifts off the home page
// and the page rises in under it.
//
// It starts as an exact copy of the launch screen (its colour, the logo at
// 3 points to the pixel in the middle of the safe area, as UILaunchScreen
// draws it), so nothing jumps when the app's first frame replaces it.
import SwiftUI
import UIKit

final class LaunchIntro: ObservableObject {
    static let shared = LaunchIntro()

    /// One flap: frames 0-15 of the strip; then a settling beat at a smaller
    /// swing, 16-30, ending back on frame 0 (the logo itself). Constant
    /// 24 fps throughout: holding frames longer to ease reads as lag.
    static let fps = 24.0
    static let frameCount = 31
    /// The strip's frame box, and where the logo sits in it (art pixels).
    static let box = CGSize(width: 56, height: 40)
    static let logoAt = CGPoint(x: 4, y: 4)
    static let logo = CGSize(width: 48, height: 29)
    /// The launch screen's logo: 432x261 pixels at @3x.
    static let launchScale: CGFloat = 3

    static let hold = 0.2
    static let glide = 1.05
    static var flapping: Double { Double(frameCount) / fps }
    static let fadeOut = 0.45

    enum Phase: Equatable { case waiting, flying(Date), done }

    @Published private(set) var phase: Phase
    /// Where the brand's logo is (window coordinates), once laid out.
    private(set) var target: CGRect?

    var active: Bool { phase != .done }

    private init() {
        let args = ProcessInfo.processInfo.arguments
        // Scripted launches open straight onto what they test.
        let scripted = ["-autoplay", "-sheet", "-home", "-menu"].contains(where: args.contains)
        phase = scripted || !Flights.canFly ? .done : .waiting
        if phase == .waiting {
            Flights.shared.beginArrival(lasting: 2, after: Self.hold + 0.1)
            // Nothing to land on (a game opened from Files at launch): the
            // cover fades anyway.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if self.phase == .waiting && !self.started {
                    withAnimation(.easeOut(duration: 0.3)) { self.phase = .done }
                }
            }
        }
    }

    /// The brand's logo reported its place: after a beat, fly to it.
    func brandAt(_ rect: CGRect) {
        guard rect.width > 0 else { return }
        target = rect
        guard phase == .waiting, !started else { return }
        started = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.hold) {
            guard self.phase == .waiting else { return }
            self.phase = .flying(Date())
            DispatchQueue.main.asyncAfter(deadline: .now() + max(Self.glide, Self.flapping)) {
                self.phase = .done
            }
        }
    }
    private var started = false

    /// The brand's logo stands down while its copy is in the air.
    var hidesBrand: Bool { active }
}

/// The launch screen's copy, then the flight.
struct LaunchIntroOverlay: View {
    @ObservedObject private var intro = LaunchIntro.shared

    private static let frames: [UIImage] = {
        guard let img = UIImage(named: "Flap")?.cgImage else { return [] }
        let w = Int(LaunchIntro.box.width), h = Int(LaunchIntro.box.height)
        return (0..<min(LaunchIntro.frameCount, img.width / w)).compactMap { i in
            img.cropping(to: CGRect(x: i * w, y: 0, width: w, height: h)).map { UIImage(cgImage: $0) }
        }
    }()

    var body: some View {
        if intro.active {
            TimelineView(.animation(paused: !isFlying)) { tl in
                let t = elapsed(tl.date)
                ZStack {
                    Color("LaunchBackground")
                        .opacity(1 - FlightOverlay.bezier(min(1, t / LaunchIntro.fadeOut), 0.4, 0, 0.6, 1))
                        .ignoresSafeArea()
                    // The safe area, as the launch screen centres its image
                    // in it.
                    GeometryReader { geo in
                        bat(t: t, safe: geo.frame(in: .global))
                    }
                }
            }
            .allowsHitTesting(phaseIsWaiting)
            .accessibilityHidden(true)
            .transition(.opacity)
        }
    }

    private var isFlying: Bool { if case .flying = intro.phase { return true } else { return false } }
    private var phaseIsWaiting: Bool { intro.phase == .waiting }

    private func elapsed(_ now: Date) -> Double {
        if case .flying(let start) = intro.phase { return max(0, now.timeIntervalSince(start)) }
        return 0
    }

    @ViewBuilder
    private func bat(t: Double, safe: CGRect) -> some View {
        let s0 = LaunchIntro.launchScale
        let logo = LaunchIntro.logo
        let fromLogo = CGRect(x: safe.midX - logo.width * s0 / 2, y: safe.midY - logo.height * s0 / 2,
                              width: logo.width * s0, height: logo.height * s0)
        let to = intro.target ?? fromLogo
        // Lifts off gently and comes in to land.
        let e = CGFloat(FlightOverlay.bezier(min(1, t / LaunchIntro.glide), 0.5, 0, 0.2, 1))
        let s = s0 + (to.width / logo.width - s0) * e
        let x = fromLogo.minX + (to.minX - fromLogo.minX) * e
        let y = fromLogo.minY + (to.minY - fromLogo.minY) * e
        let i = min(Int(t * LaunchIntro.fps), LaunchIntro.frameCount)
        let frame = i < Self.frames.count ? Self.frames[i] : Self.frames.first
        if let frame {
            Image(uiImage: frame)
                .resizable()
                .interpolation(.none)
                .frame(width: LaunchIntro.box.width * s, height: LaunchIntro.box.height * s)
                // The brand's shadow, coming in as it lands.
                .shadow(color: .black.opacity((Settings.shared.palette.isLight ? 0.25 : 0.6) * Double(e)), radius: 7, y: 4)
                .offset(x: x - LaunchIntro.logoAt.x * s - safe.minX,
                        y: y - LaunchIntro.logoAt.y * s - safe.minY)
        }
    }
}
