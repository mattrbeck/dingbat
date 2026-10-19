import XCTest

/// Linked to a browser that goes away (driven from node): the away card's
/// Disconnect takes two taps, then the session ends and the card goes.
final class LinkAwayUITests: XCTestCase {
    func testDisconnectFromAwayCard() throws {
        let env = ProcessInfo.processInfo.environment
        let app = XCUIApplication()
        app.launchArguments = ["-audio.muted", "YES", "-autoplay", env["DB_GAME"]!,
                               "-signal", env["DB_SIGNAL"]!, "-link", env["DB_CODE"]!,
                               "-link-busy-cable", "1000000000"]
        app.launch()

        let title = app.staticTexts["Friend switched away"]
        XCTAssertTrue(title.waitForExistence(timeout: 120), "the away card")
        let disconnect = app.buttons["Disconnect…"]
        XCTAssertTrue(disconnect.exists, "its Disconnect button")
        snap(app, "card")

        disconnect.tap()
        let armed = app.buttons["Are you sure?"]
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
