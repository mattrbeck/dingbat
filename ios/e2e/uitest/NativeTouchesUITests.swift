import XCTest
import notify

/// The native touches (docs/manual-verification.md, "iOS: native touches")
/// driven in the simulator: the system pauses, the deferred edge gestures,
/// the 44 pt targets and the switches as VoiceOver sees them. The app runs
/// with `-debug-events` (DebugEvents.swift): this test posts the system's
/// notifications to it as Darwin notifications and reads the game's state
/// back the same way. Run by ios/e2e/native-touches.mjs.
final class NativeTouchesUITests: XCTestCase {
    private var token: Int32 = 0
    private let game = ProcessInfo.processInfo.environment["DB_GAME"] ?? "linktest.gba"

    override func setUp() {
        continueAfterFailure = true
        notify_register_check("com.mattrb.dingbat.debug.state", &token)
    }

    private func state() -> UInt64 {
        var v: UInt64 = 0
        notify_get_state(token, &v)
        return v
    }
    private var paused: Bool { state() & 1 != 0 }
    private var menuOpen: Bool { state() & 2 != 0 }
    private var running: Bool { state() & 4 != 0 && state() & 1 == 0 }

    private func post(_ name: String) { notify_post("com.mattrb.dingbat.debug." + name) }

    @discardableResult
    private func until(_ what: String, _ timeout: Double = 5, _ cond: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if cond() { return true }
            usleep(50_000)
        }
        XCTFail("timed out: \(what) (state \(String(state(), radix: 16)))")
        return false
    }

    /// Stays so for `seconds` (a pause that should not lift).
    private func holds(_ what: String, _ seconds: Double, _ cond: () -> Bool) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if !cond() { XCTFail("did not hold: \(what) (state \(String(state(), radix: 16)))"); return }
            usleep(50_000)
        }
    }

    private func launch(_ extra: [String] = []) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-audio.muted", "YES", "-debug-events", "-autoplay", game] + extra
        app.launch()
        // A sheet opened at launch pauses the game: wait for it to load only.
        if extra.contains("-sheet") { until("the game loads", 60) { state() & 4 != 0 } }
        else { until("the game runs", 60) { running } }
        return app
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    // MARK: system pauses

    func testAudioInterruptions() {
        let app = launch()
        post("audio-began")
        until("an interruption pauses") { paused }
        XCTAssertFalse(menuOpen, "no menu for a system pause")
        post("audio-resume")
        until("shouldResume resumes") { running }

        post("audio-began")
        until("paused again") { paused }
        post("audio-ended")
        holds("no shouldResume: it stays paused", 1.5) { paused }
        snap(app, "paused-after-interruption")
        // The play bar's resume is the player's way back.
        app.buttons["Pause / Resume"].firstMatch.tap()
        until("the player resumes") { running }

        // The player's own pause during the hold wins over the resume.
        post("audio-began")
        until("paused") { paused }
        app.buttons["Pause / Resume"].firstMatch.tap()   // resume by hand: the hold is dropped
        until("resumed by hand") { running }
        app.buttons["Pause / Resume"].firstMatch.tap()   // and paused by hand
        until("paused by hand") { paused }
        post("audio-resume")
        holds("a resume after the player's pause leaves it paused", 1.5) { paused }
    }

    func testBackgroundAndControlCenter() {
        let app = launch()
        XCUIDevice.shared.press(.home)
        until("background pauses") { paused }
        app.activate()
        until("foreground resumes") { running }

        // Control Center from the top right: on the play screen the first
        // swipe is deferred (defersSystemGestures), the second opens it.
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        func pullControlCenterAt(_ x: CGFloat) {
            let from = springboard.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.0))
            let to = springboard.coordinate(withNormalizedOffset: CGVector(dx: x, dy: 0.5))
            from.press(forDuration: 0.05, thenDragTo: to)
        }
        func pullControlCenter() { pullControlCenterAt(0.95) }
        func waitPaused(_ t: Double) -> Bool {
            let end = Date().addingTimeInterval(t)
            while Date() < end { if paused { return true }; usleep(50_000) }
            return false
        }
        pullControlCenter()
        usleep(300_000)
        let first = state()
        snap(app, "after-first-swipe")
        if first & 1 == 0 { pullControlCenter() }
        if !waitPaused(3) {
            // Notification Center from the deferral's grabber, top centre.
            pullControlCenterAt(0.5)
            pullControlCenterAt(0.5)
        }
        until("Control Center / Notification Center pauses (inactive)", 5) { paused }
        snap(app, "control-center")
        print("NATIVE: first swipe left the game \(first & 1 == 0 ? "running (deferred)" : "paused (not deferred)")")
        // Away again: a tap on the game's half of the screen closes it.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.9)).tap()
        until("Control Center gone, the game resumes", 8) { running }
    }

    func testHeadphonesOutOpensTheMenu() {
        _ = launch()
        post("headphones-out")
        until("the menu opens, paused") { paused && menuOpen }
    }

    /// A GCVirtualController connected and disconnected. A pad already
    /// connected to the Mac passes through to the simulator; with one there
    /// the virtual pad is not the last and its going must not stop the game.
    func testLastPadGone() {
        _ = launch()
        sleep(1)
        let before = state() >> 32 & 0xFF
        post("pad-connect")
        until("a pad connects", 10) { state() >> 32 & 0xFF == before + 1 }
        XCTAssertEqual(state() >> 8 & 0xFF, 1, "the first pad is player 1 (index1 + 1)")
        holds("a pad connecting does not stop the game", 1) { running }
        post("pad-disconnect")
        until("a disconnect seen", 5) { state() >> 16 & 0xFF != 0 }
        let listed = (state() >> 16 & 0xFF) - 1
        print("NATIVE: pads before \(before); at the disconnect listed \(listed), the one gone listed: \(state() >> 25 & 1)")
        XCTAssertEqual(state() >> 25 & 1, 0, "the pad going is no longer listed when its notification comes")
        XCTAssertEqual(listed, before, "only the virtual pad went")
        if before == 0 {
            until("the last pad gone stops the game with the menu open") { paused && menuOpen }
        } else {
            holds("another pad still connected: the game plays on", 1.5) { running }
        }
    }

    // MARK: touch targets, switches

    func testCloseButtonTouchTarget() {
        let app = launch(["-sheet", "states"])
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the sheet's Close")
        let f = close.frame
        print("NATIVE: Close frame \(f)")
        snap(app, "states-sheet")
        XCTAssertEqual(f.width, 44, "the target is 44 pt wide (drawn 36)")
        XCTAssertEqual(f.height, 44, "and 44 pt tall")
        // 1 pt in from the target's left edge: 3 pt outside the drawn 36 pt
        // button, inside the 44 pt target only.
        let origin = app.coordinate(withNormalizedOffset: .zero)
        origin.withOffset(CGVector(dx: f.minX + 1, dy: f.midY)).tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3), "a tap 3 pt outside the drawn Close closes")
    }

    func testSwitchesAreSwitches() {
        let app = launch(["-sheet", "settings:controls"])
        let haptics = app.switches["Haptic feedback"].firstMatch
        XCTAssertTrue(haptics.waitForExistence(timeout: 10), "Haptic feedback is a switch to accessibility")
        let before = haptics.value as? String
        haptics.tap()
        let after = haptics.value as? String
        print("NATIVE: Haptic feedback switch \(before ?? "?") -> \(after ?? "?")")
        XCTAssertNotEqual(before, after, "a tap flips it")
        haptics.tap()
        snap(app, "settings-controls")
    }

    /// Signed in to a fake Drive (`-drive-stub`, DB_DRIVE): a pull down on
    /// the home screen runs a sync. The fake's request log, read by the
    /// runner, has to show requests after the printed pull time.
    func testPullToRefresh() throws {
        guard let stub = ProcessInfo.processInfo.environment["DB_DRIVE"] else {
            throw XCTSkip("no fake Drive (DB_DRIVE)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-audio.muted", "YES", "-drive-stub", stub]
        app.launch()
        sleep(12)  // the boot sync, done
        // The first-run offer to add pictures, if it came up.
        let notNow = app.buttons["Not now"]
        if notNow.exists { notNow.tap(); sleep(2) }
        snap(app, "home-before-pull")
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.3))
        let down = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.8))
        print("NATIVE: pull at \(Int(Date().timeIntervalSince1970 * 1000))")
        top.press(forDuration: 0.05, thenDragTo: down)
        usleep(400_000)
        snap(app, "home-pulled")
        sleep(5)
    }

    func testTintedCursor() {
        let app = launch(["-sheet", "link"])
        let field = app.textFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10), "the link code field")
        field.tap()
        sleep(1)
        snap(app, "link-field-cursor")
    }
}
