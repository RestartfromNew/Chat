import XCTest

final class CryptoLabUITests: XCTestCase {
    @MainActor
    func testOfflineEncryptionButtonsAndChatBubble() throws {
        continueAfterFailure = false
        let app = XCUIApplication(); app.launch()
        let tab = app.tabBars.buttons["我的"]
        if tab.exists {
            tab.tap(); app.buttons["开发调试"].tap(); app.buttons["本地加密实验"].tap()
        }
        else {
            let link = app.buttons["本地加密实验（无需登录）"]
            for _ in 0..<4 {
                if link.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(link.waitForExistence(timeout: 5)); link.tap()
        }
        func tap(_ id: String) {
            let button = app.buttons[id]
            for _ in 0..<4 {
                if button.isHittable { break }
                app.swipeUp()
            }
            XCTAssertTrue(button.waitForExistence(timeout: 3)); XCTAssertTrue(button.isEnabled)
            button.tap()
        }
        XCTAssertFalse(app.buttons["crypto.verify"].isEnabled)
        tap("crypto.generate"); tap("crypto.verify"); tap("crypto.establish")
        tap("crypto.encrypt"); tap("crypto.decrypt")
        let received = app.staticTexts["A → B · 已验证解密"]
        for _ in 0..<3 { if received.isHittable { break }; app.swipeUp() }
        XCTAssertTrue(received.waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["你好，这是加密测试。"].exists)
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Local encrypted chat"; shot.lifetime = .keepAlways; add(shot)
        tap("crypto.attack.改密文")
        XCTAssertEqual(app.staticTexts.matching(identifier: "A → B · 已验证解密").count, 1)
        XCTAssertFalse(app.staticTexts["此测试正文不得显示"].exists)
    }
}
