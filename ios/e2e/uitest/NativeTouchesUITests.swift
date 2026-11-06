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

    /// A toast raised while a sheet is up shows once, on the sheet: the root
    /// stack underneath stays hidden while the sheet draws its own.
    func testToastOverASheetShowsOnce() {
        let app = launch(["-sheet", "states"])
        let save = app.buttons["Save"].firstMatch
        XCTAssertTrue(save.waitForExistence(timeout: 10), "Save States' Save")
        save.tap()
        let toast = app.staticTexts.matching(NSPredicate(format: "label == %@", "Saved to slot 1"))
        XCTAssertTrue(toast.firstMatch.waitForExistence(timeout: 3), "the toast shows over the sheet")
        snap(app, "toast-over-sheet")
        let n = toast.count
        print("NATIVE: \"Saved to slot 1\" drawn \(n) time(s)")
        XCTAssertEqual(n, 1, "one toast, not one on the sheet and one behind it")
        app.buttons["Close"].firstMatch.tap()
        XCTAssertTrue(save.waitForNonExistence(timeout: 3), "the sheet closes")
        post("toast")
        XCTAssertTrue(app.staticTexts["Debug toast"].waitForExistence(timeout: 3),
                      "with the sheet gone the root stack shows toasts again")
    }

    /// The same under a short sheet in a game, where the root stack's copy
    /// would show above the sheet's top edge.
    func testToastOverAShortSheetShowsOnce() {
        let app = launch(["-sheet", "link"])
        XCTAssertTrue(app.staticTexts["Connect link cable"].waitForExistence(timeout: 10), "the link sheet")
        post("toast")
        let toast = app.staticTexts.matching(NSPredicate(format: "label == %@", "Debug toast"))
        XCTAssertTrue(toast.firstMatch.waitForExistence(timeout: 3), "the toast shows")
        snap(app, "toast-over-short-sheet")
        print("NATIVE: \"Debug toast\" under the link sheet drawn \(toast.count) time(s) at \(toast.firstMatch.frame)")
        XCTAssertEqual(toast.count, 1, "one toast")
    }

    // MARK: the in-game menu

    /// With the menu open the bar still works: Pause pauses and the menu
    /// goes (web: the click hides the dropdown and goes on); the hamburger
    /// still toggles it; a tap on the game only closes it.
    func testBarWorksWithTheMenuOpen() {
        let app = launch()
        let menu = app.buttons["Menu"].firstMatch
        // A folded bar (the iPhone Duo folded): a tap on the picture first.
        if !menu.isHittable { app.otherElements["Game screen"].firstMatch.tap() }
        menu.tap()
        until("the menu opens") { menuOpen }
        holds("the menu leaves the game running", 0.5) { running }
        app.buttons["Pause / Resume"].firstMatch.tap()
        until("Pause pauses with the menu open, and the menu goes") { paused && !menuOpen }
        app.buttons["Pause / Resume"].firstMatch.tap()
        until("and resumes") { running }
        menu.tap()
        until("the hamburger opens it") { menuOpen }
        menu.tap()
        until("and closes it") { !menuOpen }
        holds("closed, the game runs", 0.5) { running && !menuOpen }
        menu.tap()
        until("open again") { menuOpen }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.6)).tap()
        until("a tap below the bar closes it") { !menuOpen }
        XCTAssertTrue(running, "and the game runs")
    }

    /// Held sideways the menu is taller than the room under the bar: it
    /// stops above the bottom edge and scrolls to its last item.
    func testMenuScrollsInLandscape() {
        let app = launch(["-landscape"])
        sleep(2)
        let menu = app.buttons["Menu"].firstMatch
        if !menu.isHittable {
            // The bar folds off the top: a tap on the picture brings it down.
            app.otherElements["Game screen"].firstMatch.tap()
        }
        XCTAssertTrue(menu.waitForExistence(timeout: 3) && menu.isHittable, "the bar is down")
        menu.tap()
        until("the menu opens") { menuOpen }
        let screenH = app.windows.firstMatch.frame.height
        XCTAssertLessThan(screenH, app.windows.firstMatch.frame.width, "held sideways")
        let first = app.buttons["Main Menu"].firstMatch
        let last = app.buttons["Report a Bug"].firstMatch
        XCTAssertTrue(last.waitForExistence(timeout: 3), "Report a Bug is in the menu")
        snap(app, "menu-landscape")
        print("NATIVE: landscape height \(screenH), Report a Bug at \(last.frame)")
        if last.frame.maxY > screenH {
            first.swipeUp()
            usleep(600_000)
        }
        snap(app, "menu-landscape-scrolled")
        print("NATIVE: after a swipe Report a Bug at \(last.frame)")
        XCTAssertLessThanOrEqual(last.frame.maxY, screenH, "the last item can be scrolled on screen")
        XCTAssertTrue(last.isHittable, "and tapped")
    }

    /// Back on the home screen held sideways, the paused game's picture sits
    /// on the left and its name and buttons beside it (web ≥760px: the whole
    /// screen's width, the notch's insets too).
    func testHeroSideBySideInLandscape() {
        let app = launch(["-landscape"])
        sleep(2)
        let menu = app.buttons["Menu"].firstMatch
        if !menu.isHittable { app.otherElements["Game screen"].firstMatch.tap() }
        menu.tap()
        app.buttons["Main Menu"].firstMatch.tap()
        let picture = app.buttons["Resume game"].firstMatch
        let resume = app.buttons["Resume"].firstMatch
        XCTAssertTrue(picture.waitForExistence(timeout: 5) && resume.waitForExistence(timeout: 5), "the paused hero")
        sleep(1)
        snap(app, "hero-landscape")
        let w = app.windows.firstMatch.frame
        print("NATIVE: window \(w.size), picture \(picture.frame), Resume \(resume.frame)")
        XCTAssertLessThan(w.height, w.width, "held sideways")
        XCTAssertLessThanOrEqual(picture.frame.maxX, resume.frame.minX, "Resume is beside the picture, not under it")
        XCTAssertLessThanOrEqual(picture.frame.maxY, w.height, "the picture fits on screen")
    }

    /// The iPhone Duo folded, upright: the bar folds away, the stage takes
    /// the top edge, and a tap on the picture brings the bar down. Skipped
    /// on any other simulator.
    func testFoldedDuoPicture() throws {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        try XCTSkipUnless(model == "iPhone19,4", "the iPhone Duo's cover screen only (this is \(model))")
        let app = launch()
        sleep(1)
        let w = app.windows.firstMatch.frame
        try XCTSkipIf(w.width > 466, "folded only (this is the inner screen)")
        let picture = app.otherElements["Game screen"].firstMatch
        let menu = app.buttons["Menu"].firstMatch
        print("NATIVE: Duo window \(w.size), picture \(picture.frame), Menu \(menu.frame)")
        XCTAssertLessThan(w.width, w.height, "held upright")
        XCTAssertLessThan(menu.frame.maxY, 1, "the bar is folded off the top")
        // Where the picture sits (clear of the column) is in the snapshot:
        // the accessibility element is the stage, not the picture.
        XCTAssertEqual(picture.frame.minY, 0, "the stage starts at the top edge")
        snap(app, "duo-folded")
        picture.tap()
        XCTAssertTrue(menu.waitForExistence(timeout: 2), "a tap on the picture")
        until("brings the bar down") { menu.frame.minY >= 0 && menu.isHittable }
    }

    /// The same with "Full width, smaller buttons": the bar stays, the
    /// controls take the DS cluster's measures. Skipped elsewhere.
    func testFoldedDuoFullWidth() throws {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        try XCTSkipUnless(model == "iPhone19,4", "the iPhone Duo's cover screen only (this is \(model))")
        let app = launch(["-video.uprightPicture", "full"])
        sleep(1)
        try XCTSkipIf(app.windows.firstMatch.frame.width > 466, "folded only (this is the inner screen)")
        let menu = app.buttons["Menu"].firstMatch
        print("NATIVE: Duo full width, Menu \(menu.frame)")
        XCTAssertTrue(menu.isHittable, "the bar stays")
        snap(app, "duo-full-width")
        menu.tap()
        until("the menu opens from it") { menuOpen }
    }

    /// The iPhone Duo unfolded, upright: flat, the bar stays over a picture
    /// the screen's width; half-folded (the hinge partly open, forced here
    /// by -half-folded), the bar folds and the stage ends above the crease
    /// (the screen's middle). Skipped anywhere but the Duo's inner screen.
    func testUnfoldedDuo() throws {
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        try XCTSkipUnless(model == "iPhone19,4", "the iPhone Duo only (this is \(model))")
        var app = launch(["-no-hinge", "-portrait"])
        sleep(2)
        var w = app.windows.firstMatch.frame
        try XCTSkipIf(w.width <= 466 || w.width > w.height, "the inner screen upright only (\(w.size))")
        XCTAssertTrue(app.buttons["Menu"].firstMatch.isHittable, "flat: the bar stays")
        snap(app, "duo-unfolded-flat")
        app.terminate()
        app = launch(["-half-folded", "-portrait"])
        sleep(2)
        w = app.windows.firstMatch.frame
        let stage = app.otherElements["Game screen"].firstMatch.frame
        print("NATIVE: half-folded window \(w.size), stage \(stage)")
        XCTAssertFalse(app.buttons["Menu"].firstMatch.isHittable, "half-folded: the bar folds")
        XCTAssertLessThanOrEqual(stage.maxY, w.height / 2, "the picture stays above the crease")
        snap(app, "duo-half-folded")
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
