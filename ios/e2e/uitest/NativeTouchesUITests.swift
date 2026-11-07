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
        let first = app.buttons["Library"].firstMatch
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
        app.buttons["Library"].firstMatch.tap()
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

    /// The in-game bar, held upright (portrait only), with the fps readout
    /// up (fast-forward), and whatever else DB_BAR_ARGS adds (`-drive-stub`
    /// for the sync icon; DB_GAME a tilt cart for its button; DB_MUTE the
    /// channel-mute pill): nothing overlaps and all of it is on screen.
    /// DB_TIGHT: the row with no room for a reading, where none showing is
    /// right. Prints every item's frame (NATIVE: bar …) for comparing builds.
    /// In the suite as it stands; with the knobs, on its own, from the repo:
    ///   DB_BAR_ARGS="-drive-stub http://127.0.0.1:9" DB_MUTE=1 \
    ///     node ios/e2e/native-touches.mjs <dd> [udid]
    /// (a tilt cart for its button: DB_ROMS=<path> DB_GAME=<its name>; the
    /// SE's tightest row adds DB_TIGHT=1).
    func testTopBarFits() {
        let extra = (ProcessInfo.processInfo.environment["DB_BAR_ARGS"] ?? "")
            .split(separator: " ").map(String.init)
        let env = ProcessInfo.processInfo.environment
        var app = launch(["-speed", "ff"] + extra)
        // DB_MUTE: a channel muted (never saved, so through Settings › Audio),
        // for the bar's channel-mute pill beside the readout.
        if env["DB_MUTE"] == "1" {
            app.terminate()
            app = launch(["-speed", "ff", "-sheet", "settings:audio"] + extra)
            let channels = app.buttons["Channels"].firstMatch
            XCTAssertTrue(channels.waitForExistence(timeout: 5), "Settings › Audio › Channels")
            channels.tap()
            let muteAll = app.buttons["Mute all"].firstMatch
            XCTAssertTrue(muteAll.waitForExistence(timeout: 3), "a channel group's Mute all")
            muteAll.tap()
            app.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex
                .last { $0.isHittable }?.tap()
            sleep(1)
        }
        let menu = app.buttons["Menu"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 10), "the bar")
        if !menu.isHittable { app.otherElements["Game screen"].firstMatch.tap(); sleep(1) }
        let bar = menu.frame
        let width = app.windows.firstMatch.frame.width
        let inBar = { (e: XCUIElement) -> Bool in
            let f = e.frame
            return f.height > 0 && f.midY > bar.minY - 4 && f.midY < bar.maxY + 4
        }
        // The buttons (the sync icon is one), left to right, and the readout.
        // Any reading, with or without its unit (an older build's bare number).
        let readout = app.staticTexts.matching(NSPredicate(format: "label MATCHES '[0-9,]+( fps)?'")).firstMatch
        _ = readout.waitForExistence(timeout: 10)
        print("NATIVE: bar text '\(readout.label)' \(readout.frame)")
        let buttons = app.buttons.allElementsBoundByIndex.filter(inBar).sorted { $0.frame.minX < $1.frame.minX }
        var last: CGRect?
        for b in buttons {
            print("NATIVE: bar button '\(b.label)' \(b.frame)")
            XCTAssertGreaterThanOrEqual(b.frame.minX, 0, "\(b.label) on screen")
            XCTAssertLessThanOrEqual(b.frame.maxX, width, "\(b.label) on screen")
            if let l = last { XCTAssertLessThanOrEqual(l.maxX, b.frame.minX + 0.5, "\(b.label) clear of the one before") }
            last = b.frame
            // The readout sits between buttons, touching none.
            XCTAssertFalse(b.frame.insetBy(dx: 0.5, dy: 0.5).intersects(readout.frame), "the readout clear of \(b.label)")
        }
        // Nothing overflows: the bar keeps its 10 pt ends (an overflowing
        // HStack spills both ways and every button moves).
        if let first = buttons.first, let end = buttons.last {
            XCTAssertEqual(first.frame.minX, 10, accuracy: 0.5, "the bar's left end")
            XCTAssertEqual(end.frame.maxX, width - 10, accuracy: 0.5, "the bar's right end")
        }
        XCTAssertTrue(readout.label.hasSuffix(" fps"), "the readout says fps: \(readout.label)")
        if ProcessInfo.processInfo.environment["DB_TIGHT"] != "1" {
            XCTAssertGreaterThan(readout.frame.width, 0, "the reading shows")
        }
        snap(app, "topbar")
    }

    /// The library head's Add pictures (web .lib-thumbs): drawn 28 pt tall,
    /// smaller than Add a game (34), its touch area 44 pt (what VoiceOver
    /// and this test see as its frame), so a tap 5 pt under the drawn
    /// capsule still lands.
    func testAddPicturesButton() {
        let app = XCUIApplication()
        app.launchArguments = ["-audio.muted", "YES"]
        app.launch()
        // The first-run offer, once the boot pull is done.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 8) { notNow.tap(); sleep(1) }
        let thumbs = app.buttons["Add pictures"].firstMatch
        let add = app.buttons["Add a game"].firstMatch
        XCTAssertTrue(thumbs.waitForExistence(timeout: 5) && add.exists, "the library head's two buttons")
        print("NATIVE: Add pictures \(thumbs.frame), Add a game \(add.frame)")
        snap(app, "library-head")
        XCTAssertEqual(thumbs.frame.height, 44, accuracy: 0.5, "a 44 pt touch area")
        XCTAssertEqual(thumbs.frame.midY, add.frame.midY, accuracy: 1, "on Add a game's line")
        XCTAssertLessThanOrEqual(thumbs.frame.maxX, add.frame.minX, "beside it, before it")
        // The drawn capsule is the middle 28 pt: 19 pt under the middle is
        // 5 pt below it.
        let under = app.coordinate(withNormalizedOffset: .zero)
            .withOffset(CGVector(dx: thumbs.frame.midX, dy: thumbs.frame.midY + 19))
        under.tap()
        XCTAssertTrue(app.staticTexts["Add pictures to your library?"].waitForExistence(timeout: 3),
                      "a tap 5 pt under the capsule opens the offer")
    }

    /// Add pictures over a library whose games are on DB_ROMS (copied in by
    /// the runner): a game whose screen stays one colour (linktest.gba's
    /// white) gets no picture and keeps its cartridge; one with a real
    /// screen gets its picture. Prints the toast (NATIVE: pictures …). Run
    /// on its own (the suite's library is linktest.gba alone), from the repo:
    ///   DB_ROMS=tests/roms/gbedge.gb DB_PICTURES="1 picture added" \
    ///     node ios/e2e/native-touches.mjs <dd>
    func testAddPicturesSkipsBlank() throws {
        guard let want = ProcessInfo.processInfo.environment["DB_PICTURES"] else {
            throw XCTSkip("no DB_PICTURES (the pictures the run should add)")
        }
        let app = XCUIApplication()
        app.launchArguments = ["-audio.muted", "YES", "-sheet", "addPictures"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Add pictures to your library?"].waitForExistence(timeout: 10), "the offer")
        sleep(1)
        // The sheet's, not the library head's behind it.
        let go = app.buttons.matching(NSPredicate(format: "label == 'Add pictures'")).allElementsBoundByIndex
            .last { $0.isHittable }
        XCTAssertNotNil(go, "the offer's Add pictures")
        go?.tap()
        let done = app.staticTexts.matching(NSPredicate(format: "label ENDSWITH 'added' OR label ENDSWITH 'stopping'")).firstMatch
        XCTAssertTrue(done.waitForExistence(timeout: 60), "the run ends")
        print("NATIVE: pictures \(done.label)")
        XCTAssertEqual(done.label, want, "only the real screens are pictured")
        sleep(1)
        snap(app, "pictures-added")
    }

    /// A game's toasts (web 720bc7e3): under the bar, never over its buttons;
    /// the open game menu draws over them; held sideways, between the
    /// shoulder columns (clear of L, R and a DS's Select and Start under R).
    func testToastsInPlay() {
        let long = "Play by tilting your device? Your game reads the tilt sensor instead of the buttons while this is on"
        var app = launch(["-toast", long])
        let toast = app.staticTexts[long].firstMatch
        XCTAssertTrue(toast.waitForExistence(timeout: 8), "the toast")
        let menu = app.buttons["Menu"].firstMatch
        print("NATIVE: toast \(toast.frame), bar's Menu \(menu.frame)")
        XCTAssertGreaterThanOrEqual(toast.frame.minY, menu.frame.maxY, "under the bar's buttons")
        menu.tap()
        XCTAssertTrue(app.buttons["Library"].firstMatch.waitForExistence(timeout: 3), "the menu opens")
        sleep(1)
        snap(app, "toast-under-menu")
        // The menu's quick row lies where the toast is: on top, it takes the tap.
        let quickSave = app.buttons["Quick Save"].firstMatch
        XCTAssertTrue(quickSave.frame.intersects(toast.frame), "the quick row under the toast's place")
        XCTAssertTrue(quickSave.isHittable, "the open menu draws over the toast")
        app.terminate()

        app = launch(["-landscape", "-toast", long])
        let side = app.staticTexts[long].firstMatch
        XCTAssertTrue(side.waitForExistence(timeout: 8), "the toast, held sideways")
        sleep(1)
        let w = app.windows.firstMatch.frame
        print("NATIVE: sideways window \(w.size), toast \(side.frame)")
        XCTAssertLessThan(w.height, w.width, "held sideways")
        // The safe region's edges, from the bar slid in: its ends sit 10 pt
        // inside them.
        app.otherElements["Game screen"].firstMatch.tap()
        let barMenu = app.buttons["Menu"].firstMatch, mute = app.buttons["Unmute"].firstMatch
        XCTAssertTrue(barMenu.waitForExistence(timeout: 3) && mute.exists, "the bar")
        sleep(1)
        let lead = barMenu.frame.minX - 10, trail = mute.frame.maxX + 10
        print("NATIVE: sideways safe region \(lead)…\(trail), toast \(side.frame)")
        XCTAssertGreaterThanOrEqual(side.frame.minX, lead + 134 - 0.5, "clear of L's column")
        XCTAssertLessThanOrEqual(side.frame.maxX, trail - 134 + 0.5, "clear of R's column and the rail under it")
        snap(app, "toast-sideways")
    }

    /// One armed look in every theme (web :root .armed): the game menu's
    /// Delete and Settings' Reset all settings, armed, pictured per theme.
    /// The fill and its ink are the same in each (Theme.swift dangerFill).
    func testArmedLookPerTheme() {
        // -theme is saved: the default back for the tests after this one.
        addTeardownBlock { [self] in launch(["-theme", "night", "-sheet", "tile"]).terminate() }
        func armed(_ app: XCUIApplication, _ question: String) -> XCUIElement {
            app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", question)).firstMatch
        }
        for theme in ["night", "light", "indigo", "famicom"] {
            let app = launch(["-theme", theme, "-sheet", "tile"])
            let delete = app.buttons["Delete"].firstMatch
            XCTAssertTrue(delete.waitForExistence(timeout: 5), "\(theme): the game's menu")
            delete.tap()
            XCTAssertTrue(armed(app, "Delete this game?").waitForExistence(timeout: 2),
                          "\(theme): Delete armed")
            snap(app, "armed-menu-\(theme)")
            app.terminate()
            let again = launch(["-theme", theme, "-sheet", "settings:general"])
            let reset = again.buttons["Reset all settings"].firstMatch
            XCTAssertTrue(reset.waitForExistence(timeout: 5), "\(theme): Settings › General")
            again.swipeUp()
            again.swipeUp()
            reset.tap()
            XCTAssertTrue(armed(again, "Reset all settings?").waitForExistence(timeout: 2),
                          "\(theme): Reset all settings armed")
            snap(again, "armed-button-\(theme)")
            again.terminate()
        }
    }

    /// Sign out everywhere (a fake Drive account, `-drive-stub` at a closed
    /// port: signed in, nothing syncs): the armed fill bleeds past the text
    /// and nothing moves, in Settings › General and the account popover.
    func testSignOutEverywhereArmed() {
        let app = XCUIApplication()
        app.launchArguments = ["-audio.muted", "YES", "-drive-stub", "http://127.0.0.1:9",
                               "-sheet", "settings:general"]
        app.launch()
        let out = app.buttons["Sign out everywhere"].firstMatch
        XCTAssertTrue(out.waitForExistence(timeout: 10), "Settings › General: signed in")
        app.swipeUp()
        sleep(1)
        let email = app.staticTexts["player@example.com"].firstMatch
        let before = out.frame
        print("NATIVE: settings unarmed \(before), email \(email.frame)")
        snap(app, "signout-settings")
        out.tap()
        let armed = app.buttons["Sign out everywhere?"].firstMatch
        XCTAssertTrue(armed.waitForExistence(timeout: 2), "armed")
        print("NATIVE: settings armed \(armed.frame)")
        XCTAssertEqual(armed.frame.minX, before.minX, accuracy: 0.5, "the text does not move")
        XCTAssertEqual(armed.frame.minY, before.minY, accuracy: 0.5, "nor the row")
        XCTAssertEqual(armed.frame.height, before.height, accuracy: 0.5, "still one line")
        snap(app, "signout-settings-armed")
        app.terminate()

        app.launchArguments = ["-audio.muted", "YES", "-drive-stub", "http://127.0.0.1:9"]
        app.launch()
        // The first-run offer to add pictures, once the boot pull is done.
        let notNow = app.buttons["Not now"]
        if notNow.waitForExistence(timeout: 10) { notNow.tap(); sleep(1) }
        let account = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Google Drive:'")).firstMatch
        XCTAssertTrue(account.waitForExistence(timeout: 5), "the account button")
        print("NATIVE: account \(account.label) \(account.frame)")
        snap(app, "signout-home")
        account.tap()
        sleep(1)
        let pop = app.buttons["Sign out everywhere"].firstMatch
        XCTAssertTrue(pop.waitForExistence(timeout: 3), "the account popover")
        let sync = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Sync'")).firstMatch
        let popBefore = pop.frame
        print("NATIVE: popover unarmed \(popBefore), sync \(sync.frame)")
        snap(app, "signout-popover")
        pop.tap()
        let popArmed = app.buttons["Sign out everywhere?"].firstMatch
        XCTAssertTrue(popArmed.waitForExistence(timeout: 2), "armed in the popover")
        print("NATIVE: popover armed \(popArmed.frame)")
        XCTAssertEqual(popArmed.frame.minY, popBefore.minY, accuracy: 0.5, "the row does not move")
        XCTAssertEqual(popArmed.frame.height, popBefore.height, accuracy: 0.5, "still one line")
        XCTAssertEqual(popArmed.frame.maxX, popBefore.maxX, accuracy: 0.5, "its right edge stays")
        snap(app, "signout-popover-armed")
        app.terminate()
    }

    /// Held sideways, the game's menu scrolls under its head, and the
    /// head's × stays and closes it.
    func testGameMenuCloseHeldSideways() {
        let app = launch(["-landscape"])
        sleep(2)
        let menu = app.buttons["Menu"].firstMatch
        if !menu.isHittable { app.otherElements["Game screen"].firstMatch.tap() }
        menu.tap()
        app.buttons["Library"].firstMatch.tap()
        let more = app.buttons["More for this game"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the paused hero's ⋯")
        more.tap()
        let states = app.buttons["Save states"].firstMatch
        XCTAssertTrue(states.waitForExistence(timeout: 3), "the menu, Play group and all")
        sleep(1)
        // Down to Delete: the rows scroll under the head, the × stays.
        let delete = app.buttons["Delete"].firstMatch
        for _ in 0..<3 where !delete.isHittable { states.swipeUp(); usleep(500_000) }
        XCTAssertTrue(delete.isHittable, "scrolled to Delete")
        let closeX = { app.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex
            .last { $0.isHittable } }
        let x = closeX()
        print("NATIVE: sideways menu scrolled, Delete \(delete.frame), × \(x?.frame ?? .zero)")
        snap(app, "game-menu-sideways-scrolled")
        XCTAssertNotNil(x, "the × still there")
        if let x { XCTAssertLessThan(x.frame.maxY, delete.frame.minY, "above the rows, in the head") }
        x?.tap()
        XCTAssertTrue(delete.waitForNonExistence(timeout: 3), "and it closes the menu")
    }

    /// One menu per game (web openTileMenu): the paused hero's ⋯ opens the
    /// game's menu with its Play group above the file items; Delete arms on
    /// one tap and disarms after 3.5 s; a Play row opens its sheet; closed,
    /// the same ⋯ has no Play group.
    func testOneMenuPerGame() {
        let app = launch()
        sleep(2)
        let menu = app.buttons["Menu"].firstMatch
        if !menu.isHittable { app.otherElements["Game screen"].firstMatch.tap() }
        menu.tap()
        app.buttons["Library"].firstMatch.tap()
        let more = app.buttons["More for this game"].firstMatch
        XCTAssertTrue(more.waitForExistence(timeout: 5), "the paused hero's ⋯")
        more.tap()
        let states = app.buttons["Save states"].firstMatch
        XCTAssertTrue(states.waitForExistence(timeout: 3), "Play: Save states")
        for label in ["Manage saves", "Link cable", "Cheats", "Report a bug", "Rename", "Export…", "Delete"] {
            XCTAssertTrue(app.buttons[label].firstMatch.exists, "\(label) is in the menu")
        }
        XCTAssertTrue(app.staticTexts["PLAY"].exists && app.staticTexts["GAME"].exists, "the two groups' headings")
        snap(app, "game-menu-paused")
        let delete = app.buttons["Delete"].firstMatch
        XCTAssertTrue(delete.isHittable, "Delete fits on screen")
        delete.tap()
        let armed = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@",
                                                     "Delete this game?")).firstMatch
        XCTAssertTrue(armed.waitForExistence(timeout: 2), "one tap arms Delete")
        XCTAssertTrue(armed.label.contains("Closes it; the ROM and its save data go"),
                      "the line under it says what goes: \(armed.label)")
        snap(app, "game-menu-armed")
        XCTAssertTrue(delete.waitForExistence(timeout: 5), "and it disarms")
        XCTAssertFalse(armed.exists, "its question gone")
        states.tap()
        XCTAssertTrue(app.staticTexts["Save States"].firstMatch.waitForExistence(timeout: 3), "Save states opens its sheet")
        sleep(1)
        // The sheet's Close, not the hero's under it.
        app.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex
            .last { $0.isHittable }?.tap()
        sleep(1)
        XCTAssertFalse(app.staticTexts["Save States"].exists, "the sheet closed")
        let close = app.buttons["Close"].firstMatch
        XCTAssertTrue(close.waitForExistence(timeout: 3), "the hero's Close")
        close.tap()
        sleep(1)
        more.tap()
        XCTAssertTrue(app.buttons["Rename"].firstMatch.waitForExistence(timeout: 3), "closed: the game's menu")
        XCTAssertFalse(app.buttons["Save states"].exists, "closed: no Play group")
        XCTAssertFalse(app.staticTexts["PLAY"].exists, "nor its heading")
        snap(app, "game-menu-closed")
        // Its own × closes it (held sideways it has no grabber or scrim).
        let x = app.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex
            .last { $0.isHittable }
        XCTAssertNotNil(x, "the menu's ×")
        x?.tap()
        XCTAssertTrue(app.buttons["Rename"].firstMatch.waitForNonExistence(timeout: 3), "the × closes the menu")
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
