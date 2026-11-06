#if DEBUG
import AVFAudio
import Foundation
import GameController
import notify

/// Dev hook for ios/e2e/uitest/NativeTouchesUITests.swift, on with
/// `-debug-events`: the system events the app answers, posted from a UI test
/// as Darwin notifications (the test runner and the app share the
/// simulator's notify centre), and the game's state published back.
///
///   com.mattrb.dingbat.debug.audio-began        an audio interruption begins
///   com.mattrb.dingbat.debug.audio-ended        ... ends, iOS says not to resume
///   com.mattrb.dingbat.debug.audio-resume       ... ends with shouldResume
///   com.mattrb.dingbat.debug.headphones-out     route change, old device unavailable
///   com.mattrb.dingbat.debug.pad-connect        a GCVirtualController connects
///   com.mattrb.dingbat.debug.pad-disconnect     ... and disconnects
///
/// The interruption and route notifications are the ones AVAudioSession
/// posts, with the userInfo it gives them, so what runs is the app's own
/// observers; the pad is a real GameController connection.
///
/// State: `com.mattrb.dingbat.debug.state` (notify_get_state), bit 0 the game
/// paused, bit 1 the menu open, bit 2 a game running, bits 8-15 the first
/// extended gamepad's playerIndex + 1 (0 none), bits 16-24 what the last
/// GCControllerDidDisconnect saw (lastDisconnect).
enum DebugEvents {
    static let prefix = "com.mattrb.dingbat.debug."
    private static var stateToken: Int32 = 0
    private static var tokens: [Int32] = []
    private static var pad: GCVirtualController?

    static func startIfAsked() {
        guard ProcessInfo.processInfo.arguments.contains("-debug-events") else { return }
        notify_register_check(prefix + "state", &stateToken)
        let handlers: [(String, () -> Void)] = [
            ("audio-began", { interruption(.began, resume: false) }),
            ("audio-ended", { interruption(.ended, resume: false) }),
            ("audio-resume", { interruption(.ended, resume: true) }),
            ("headphones-out", {
                NotificationCenter.default.post(
                    name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                    userInfo: [AVAudioSessionRouteChangeReasonKey:
                                AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
            }),
            ("pad-connect", {
                let cfg = GCVirtualController.Configuration()
                cfg.elements = [GCInputDirectionPad, GCInputButtonA, GCInputButtonB]
                let v = GCVirtualController(configuration: cfg)
                pad = v
                v.connect { _ in }
            }),
            ("pad-disconnect", { pad?.disconnect(); pad = nil }),
        ]
        for (name, run) in handlers {
            var token: Int32 = 0
            notify_register_dispatch(prefix + name, &token, .main) { _ in run() }
            tokens.append(token)
        }
        NotificationCenter.default.addObserver(
            forName: .GCControllerDidDisconnect, object: nil, queue: .main) { n in
            let listed = GCController.controllers().filter { $0.extendedGamepad != nil }
            let gone = n.object as? GCController
            let had = gone?.extendedGamepad != nil
            let same = listed.contains { $0 === gone }
            lastDisconnect = UInt64(min(listed.count, 254) + 1) | (had ? 0x100 : 0) | (same ? 0x200 : 0)
        }
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in publish() }
    }

    /// At the last GCControllerDidDisconnect: extended pads still listed + 1,
    /// and bit 8 whether the one gone had an extended profile.
    private static var lastDisconnect: UInt64 = 0

    private static func interruption(_ type: AVAudioSession.InterruptionType, resume: Bool) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if type == .ended {
            info[AVAudioSessionInterruptionOptionKey] =
                resume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : UInt(0)
        }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), userInfo: info)
    }

    private static func publish() {
        let s = GameSession.shared, m = AppModel.shared
        var v: UInt64 = 0
        if s.paused { v |= 1 }
        if m.menuOpen { v |= 2 }
        if s.game != nil { v |= 4 }
        if let c = GCController.controllers().first(where: { $0.extendedGamepad != nil }) {
            v |= UInt64((c.playerIndex.rawValue + 1) & 0xFF) << 8
        }
        v |= lastDisconnect << 16
        v |= UInt64(min(GCController.controllers().filter { $0.extendedGamepad != nil }.count, 255)) << 32
        notify_set_state(stateToken, v)
    }
}
#endif
