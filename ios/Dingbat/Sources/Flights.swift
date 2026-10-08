// Picture flights (web "Flights"): the game's picture travels between the
// hero (or a tile) and the screen, so going home and coming back read as the
// same thing moving rather than one screen replacing another. What flies is a
// copy laid over everything; the real screen (or the hero's picture) stays
// hidden and the game held until the copy lands on it, so no frame runs
// underneath.
//
// Two kinds of landing. A picture that IS the first frame the game will show
// (the paused game, or a session that goes back in) lands intact. One that is
// not - the closed hero's Play, or a game with no session to resume - darkens
// to black on the way and the screen powers on from black.
import SwiftUI
import UIKit

final class Flights: ObservableObject {
    static let shared = Flights()

    #if DEBUG
    /// `-flight-slow N`: flights N times slower, for screenshots.
    static let slow: Double = {
        let a = ProcessInfo.processInfo.arguments
        guard let i = a.firstIndex(of: "-flight-slow"), i + 1 < a.count else { return 1 }
        return Double(a[i + 1]) ?? 1
    }()
    #else
    static let slow = 1.0
    #endif
    static let duration = 0.46 * slow
    static let powerOnDuration = 0.7 * slow

    /// What flies, laid out at the destination's size.
    struct Flight {
        var image: UIImage
        /// .fit: a game frame, on black (its own shape at either end);
        /// .fill: box art or a tile drawn as it stands.
        var mode: ContentMode
        var from: CGRect
        var to: CGRect
        var fromRadius: CGFloat
        var toRadius: CGFloat
        /// Fades to black on the way (not the frame about to be shown).
        var dark = false
        /// The picture it lands as, faded in over the middle.
        var land: UIImage?
        var start: Date = .distantFuture
        var target: Target = .screen
    }

    /// Where it is going, once that is on screen.
    enum Target: Equatable { case screen, hero }

    /// The game's screen and the hero's picture are hidden while a copy is on
    /// its way to them.
    @Published private(set) var hiding: Target?
    @Published private(set) var flight: Flight?
    /// The screen coming on from black after a dark landing.
    @Published private(set) var powerOn: (rect: CGRect, start: Date)?
    /// The home screen rising in under a picture coming home (or the
    /// opening's logo), each part `arrivalDelay` later than its own delay.
    private(set) var arriving = false
    private(set) var arrivalDelay = 0.0

    func beginArrival(lasting: Double, after delay: Double = 0) {
        arriving = true
        arrivalDelay = delay
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + lasting * Self.slow) {
            if self.gen == g { self.arriving = false; self.arrivalDelay = 0 }
        }
    }

    /// Where each picture is now, in window coordinates: "screen", "hero",
    /// "tile:<id>".
    private var rects: [String: CGRect] = [:]
    private var pending: (target: Target, flight: Flight, at: Date)?
    private var source: (key: String, entry: RomEntry, at: Date)?
    private var gen = 0

    private init() {}

    static var canFly: Bool { !UIAccessibility.isReduceMotionEnabled }

    // MARK: anchors

    func report(_ key: String, _ rect: CGRect) {
        guard rect.width > 0 else { return }
        rects[key] = rect
        if let p = pending, key == Self.key(p.target) { DispatchQueue.main.async { self.takePending() } }
    }

    func forget(_ key: String) { rects[key] = nil }

    private static func key(_ t: Target) -> String { t == .screen ? "screen" : "hero" }

    // MARK: arming

    /// A tap on a tile or the hero, about to open `entry`: where its picture
    /// flies from.
    func source(_ key: String, _ entry: RomEntry) {
        source = (key, entry, Date())
    }

    /// A game opening from the source tapped for it: fly onto the screen.
    /// `resumed`: its session went back in, so the session's picture is the
    /// frame it lands on; otherwise it powers on from black.
    func launching(_ entry: RomEntry, resumed: Bool) {
        defer { source = nil }
        // A DS game's picture is its top screen and its stage two screens:
        // no frame to fly between them (the screens just come on).
        guard Self.canFly, !entry.isNDS, let s = source, s.entry == entry, Date().timeIntervalSince(s.at) < 60,
              let from = rects[s.key] else { return }
        let hero = s.key == "hero"
        // What the picture shows now: the hero's preferring the session's
        // own, the tile's the last screen.
        let pics = HomePictures.shared
        let shown = pics.picture(entry, preferSession: hero)
        let sessionPic = resumed ? RomLibrary.shared.sessionPicture(entry) : nil
        // The hero showing the session's own picture lands intact; anything
        // else lands as the session's picture where there is one.
        let intact = resumed && hero && HomePictures.shared.hasSession(entry) && shown != nil
        var f: Flight
        if let shown {
            f = Flight(image: shown, mode: .fit, from: from, to: .zero, fromRadius: hero ? 14 : 0, toRadius: 0)
        } else if let art = pics.art(entry) {
            f = Flight(image: art, mode: .fill, from: from, to: .zero, fromRadius: hero ? 14 : 0, toRadius: 0)
        } else if let snap = MainActor.assumeIsolated({ Self.snapshot(entry, size: from.size) }) {
            f = Flight(image: snap, mode: .fill, from: from, to: .zero, fromRadius: hero ? 14 : 0, toRadius: 0)
        } else { return }
        if !intact {
            if let sessionPic { f.land = sessionPic } else { f.dark = true }
        }
        arm(.screen, f)
        GameSession.shared.holdForFlight(true)
    }

    /// The game in memory going back on screen from the paused hero (or its
    /// tile): the frame grows back into the screen, and play goes on when it
    /// gets there.
    func resuming(_ entry: RomEntry) {
        defer { source = nil }
        guard Self.canFly, !entry.isNDS, let s = source, s.entry == entry, let from = rects[s.key],
              let img = GameSession.shared.currentImage() else { return }
        arm(.screen, Flight(image: img, mode: .fit, from: from, to: .zero,
                            fromRadius: s.key == "hero" ? 14 : 0, toRadius: 0))
        GameSession.shared.holdForFlight(true)
    }

    /// Main Menu: the screen shrinks into the hero's frame while the page
    /// rises in under it. Measured while the screen is still up.
    func goingHome() {
        cancel()
        source = nil
        let s = GameSession.shared
        guard Self.canFly, !s.twoPlayer, !s.isNDS, !NetLink.shared.linked,
              let from = rects["screen"], let img = s.currentImage() else { return }
        beginArrival(lasting: 0.9)
        arm(.hero, Flight(image: img, mode: .fit, from: from, to: .zero, fromRadius: 0, toRadius: 14))
    }

    private func arm(_ target: Target, _ f: Flight) {
        cancel()
        var f = f
        f.target = target
        pending = (target, f, Date())
        hiding = target
        // A flight that never gets to run (the app put away mid-launch) must
        // not hold the game or hide the picture for good.
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5 * Self.slow) {
            if self.gen == g && self.pending != nil { self.cancel() }
        }
        // Any rect held for it is from before; the target's next report
        // (it coming on screen) starts the flight.
        rects[Self.key(target)] = nil
    }

    /// The target is on screen: give the layout a beat, then fly onto where
    /// it is now.
    private func takePending() {
        guard let p = pending, let to = rects[Self.key(p.target)] else { return }
        pending = nil
        var f = p.flight
        f.to = to
        f.start = Date()
        flight = f
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.duration) {
            guard self.gen == g else { return }
            self.land(f)
        }
    }

    private func land(_ f: Flight) {
        flight = nil
        hiding = nil
        if f.target == .screen {
            GameSession.shared.holdForFlight(false)
            if f.dark, let r = rects["screen"] {
                let start = Date()
                powerOn = (r, start)
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.powerOnDuration) {
                    if self.powerOn?.start == start { self.powerOn = nil }
                }
            }
        }
    }

    /// Anything in the air stops where it is: the picture shows, the game
    /// goes on.
    func cancel() {
        gen += 1
        pending = nil
        flight = nil
        hiding = nil
        powerOn = nil
        GameSession.shared.holdForFlight(false)
    }

    /// A tile with neither a picture nor box art, drawn as it stands (the
    /// cartridge on its system's colour).
    @MainActor
    private static func snapshot(_ e: RomEntry, size: CGSize) -> UIImage? {
        let r = ImageRenderer(content: GamePicture(entry: e)
            .frame(width: size.width, height: size.height)
            .environment(\.palette, Settings.shared.palette))
        r.scale = UIScreen.main.scale
        return r.uiImage
    }
}

extension View {
    /// Reports where this picture is to the flights (window coordinates).
    func flightAnchor(_ key: String) -> some View {
        background(GeometryReader { g in
            let r = g.frame(in: .global)
            Color.clear
                .onAppear { Flights.shared.report(key, r) }
                .onChange(of: r) { Flights.shared.report(key, $0) }
                .onDisappear { Flights.shared.forget(key) }
        })
    }

    /// Hidden while a copy flies onto it.
    func flightHidden(_ target: Flights.Target) -> some View {
        modifier(FlightHidden(target: target))
    }

    /// Rises in under a picture coming home (web #home.home-arriving).
    func homeRise(_ delay: Double) -> some View {
        modifier(HomeRise(delay: delay))
    }
}

private struct FlightHidden: ViewModifier {
    @ObservedObject private var flights = Flights.shared
    let target: Flights.Target
    func body(content: Content) -> some View {
        content.opacity(flights.hiding == target ? 0 : 1)
    }
}

private struct HomeRise: ViewModifier {
    let delay: Double
    @State private var up = !Flights.shared.arriving
    func body(content: Content) -> some View {
        content
            .opacity(up ? 1 : 0)
            .offset(y: up ? 0 : 14)
            .onAppear {
                guard !up else { return }
                withAnimation(.timingCurve(0.2, 0.8, 0.2, 1, duration: 0.5 * Flights.slow)
                    .delay((delay + Flights.shared.arrivalDelay) * Flights.slow)) { up = true }
            }
    }
}

/// The copy in the air, over everything but the sheets.
struct FlightOverlay: View {
    @ObservedObject private var flights = Flights.shared

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .topLeading) {
                if let p = flights.powerOn {
                    TimelineView(.animation) { tl in
                        let t = min(1, tl.date.timeIntervalSince(p.start) / Flights.powerOnDuration)
                        // Held black over the first 15%, then fading out.
                        let k = t < 0.15 ? 0 : (t - 0.15) / 0.85
                        Color.black
                            .opacity(1 - Self.easeOut(k))
                            .frame(width: p.rect.width, height: p.rect.height)
                            .offset(x: p.rect.minX - origin.x, y: p.rect.minY - origin.y)
                    }
                }
                if let f = flights.flight {
                    TimelineView(.animation) { tl in
                        flier(f, t: min(1, max(0, tl.date.timeIntervalSince(f.start) / Flights.duration)), origin: origin)
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func flier(_ f: Flights.Flight, t: Double, origin: CGPoint) -> some View {
        let e = CGFloat(Self.bezier(t))
        func lerp(_ a: CGFloat, _ b: CGFloat) -> CGFloat { a + (b - a) * e }
        let rect = CGRect(x: lerp(f.from.minX, f.to.minX) - origin.x, y: lerp(f.from.minY, f.to.minY) - origin.y,
                          width: lerp(f.from.width, f.to.width), height: lerp(f.from.height, f.to.height))
        // Linear in time, as the web's (wall clock, not the eased path).
        let shade = Self.ramp(t, 0.15, 0.8)
        let landing = Self.ramp(t, 0.1, 0.6)
        return ZStack {
            Color.black
            picture(f.image, f.mode, rect.size)
            if let land = f.land {
                picture(land, .fit, rect.size).opacity(landing)
            }
            if f.dark {
                Color.black.opacity(shade)
            }
        }
        .frame(width: rect.width, height: rect.height)
        .clipShape(RoundedRectangle(cornerRadius: lerp(f.fromRadius, f.toRadius)))
        .shadow(color: .black.opacity(0.5), radius: 30, y: 24)
        .offset(x: rect.minX, y: rect.minY)
    }

    private func picture(_ img: UIImage, _ mode: ContentMode, _ size: CGSize) -> some View {
        Image(uiImage: img)
            .resizable()
            .interpolation(mode == .fit ? .none : .medium)
            .aspectRatio(contentMode: mode)
            .frame(width: size.width, height: size.height)
            .clipped()
    }

    /// 0 until `a`, 1 from `b`, linear between.
    private static func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
        t <= a ? 0 : t >= b ? 1 : (t - a) / (b - a)
    }

    private static func easeOut(_ t: Double) -> Double { bezier(t, 0, 0, 0.58, 1) }

    /// CSS cubic-bezier(x1, y1, x2, y2) at time t (the web's FLIGHT_EASE by
    /// default).
    static func bezier(_ t: Double, _ x1: Double = 0.2, _ y1: Double = 0.8,
                       _ x2: Double = 0.2, _ y2: Double = 1) -> Double {
        if t <= 0 { return 0 }
        if t >= 1 { return 1 }
        func c(_ s: Double, _ p1: Double, _ p2: Double) -> Double {
            let u = 1 - s
            return 3 * u * u * s * p1 + 3 * u * s * s * p2 + s * s * s
        }
        // Solve x(s) = t by bisection: monotone in s for these curves.
        var lo = 0.0, hi = 1.0, s = t
        for _ in 0..<24 {
            s = (lo + hi) / 2
            if c(s, x1, x2) < t { lo = s } else { hi = s }
        }
        return c(s, y1, y2)
    }
}
