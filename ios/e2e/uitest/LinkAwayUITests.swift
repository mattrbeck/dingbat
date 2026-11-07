import XCTest
import notify

/// Linked to a browser that goes away (driven from node): the away card's
/// Disconnect takes two taps, then the session ends and the card goes.
final class LinkAwayUITests: XCTestCase {
    func testDisconnectFromAwayCard() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-audio.muted", "YES", "-autoplay", env["DB_GAME"]!,
                               "-signal", env["DB_SIGNAL"]!, "-link", env["DB_CODE"]!,
                               "-link-busy-cable", "1000000000", "-debug-events"]
        app.launch()

        // DB_PAD: the menu's Disconnect by a controller alone, armed and
        // then confirmed by two presses of A (the focus stays on the row
        // when its label turns to "Disconnect?"). The session ends here.
        if env["DB_PAD"] == "1" {
            let pill = app.buttons["Disconnect link cable"].firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 120), "linked")
            let menu = app.buttons["Menu"].firstMatch
            if !menu.isHittable { app.otherElements["Game screen"].firstMatch.tap(); sleep(1) }
            menu.tap()
            XCTAssertTrue(app.buttons["Disconnect"].firstMatch.waitForExistence(timeout: 3), "the menu's Disconnect")
            func nav(_ k: String) { notify_post("com.mattrb.dingbat.debug.nav-" + k); usleep(400_000) }
            nav("down")  // the ring shows, on Library
            nav("down")  // Disconnect
            nav("a")
            XCTAssertTrue(app.buttons["Disconnect?"].firstMatch.waitForExistence(timeout: 2), "A arms it")
            snap(app, "pad-armed")
            nav("a")
            XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 5), "a second A disconnects")
            XCTAssertFalse(pill.exists, "the link has ended")
            sleep(4)
            return
        }

        // DB_BAR (node holds the browser here a while): the bar's Disconnect
        // and the menu's, each armed by one tap, pictured, left to disarm.
        if env["DB_BAR"] == "1" {
            let pill = app.buttons["Disconnect link cable"].firstMatch
            XCTAssertTrue(pill.waitForExistence(timeout: 120), "linked: the bar's Disconnect")
            let menu = app.buttons["Menu"].firstMatch
            if !pill.isHittable { app.otherElements["Game screen"].firstMatch.tap(); sleep(1) }
            pill.tap()
            usleep(500_000)
            snap(app, "bar-armed")
            sleep(4)
            menu.tap()
            let item = app.buttons["Disconnect"].firstMatch
            XCTAssertTrue(item.waitForExistence(timeout: 3), "the menu's Disconnect")
            item.tap()
            XCTAssertTrue(app.buttons["Disconnect?"].firstMatch.waitForExistence(timeout: 2), "one tap arms it")
            snap(app, "menu-armed")
            sleep(4)
            XCTAssertTrue(item.waitForExistence(timeout: 2), "and it disarms")
            menu.tap()
            sleep(1)
        }

        let title = app.staticTexts["Friend switched away"]
        XCTAssertTrue(title.waitForExistence(timeout: 120), "the away card")
        let disconnect = app.buttons["Disconnect"]
        XCTAssertTrue(disconnect.exists, "its Disconnect button")
        snap(app, "card")

        disconnect.tap()
        let armed = app.buttons["Disconnect?"]
        XCTAssertTrue(armed.waitForExistence(timeout: 3), "one tap arms it")
        XCTAssertTrue(title.exists, "still linked after one tap")
        snap(app, "armed")

        // Left alone it disarms (3.5 s), as everywhere else in the app.
        XCTAssertTrue(disconnect.waitForExistence(timeout: 6), "disarms after 3.5 s")
        disconnect.tap()
        XCTAssertTrue(armed.waitForExistence(timeout: 3))
        armed.tap()

        XCTAssertTrue(app.staticTexts["Disconnected"].waitForExistence(timeout: 5), "the toast")
        XCTAssertFalse(title.exists, "the card goes with the session")
        snap(app, "after")
        // Let node see the browser's side end before the app is torn down.
        sleep(4)
    }

    private func snap(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }
}
