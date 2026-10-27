import XCTest

final class ChatUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEnglishAndInAppLanguageSwitch() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields.firstMatch.waitForExistence(timeout: 10))
        app.swipeUp()
        let picker = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Language")).firstMatch
        XCTAssertTrue(picker.waitForExistence(timeout: 3))
        picker.tap(); app.buttons["English"].tap()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["Start with hello"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["Email"].exists)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Start with hello"].waitForExistence(timeout: 10))
        app.swipeUp()
        picker.tap(); app.buttons["简体中文"].tap()
        app.swipeDown()
        XCTAssertTrue(app.staticTexts["从一句你好开始"].waitForExistence(timeout: 5))
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = "Chinese after language switch"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor
    func testRegistrationFieldsAndServerValidation() throws {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["从一句你好开始"].waitForExistence(timeout: 10))
        app.segmentedControls.buttons["注册"].tap()
        XCTAssertTrue(app.textFields["用户名，例如 alice_chat"].exists)
        XCTAssertTrue(app.textFields["显示名称，例如 Alice"].exists)
        XCTAssertFalse(app.buttons["创建账户"].isEnabled)
        app.segmentedControls.buttons["登录"].tap()
        app.buttons["服务器设置"].tap()
        let field = app.textFields["HTTPS 地址"]
        XCTAssertTrue(field.waitForExistence(timeout: 3))
        field.tap()
        let old = (field.value as? String) ?? ""
        field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: old.count))
        field.typeText("http://example.com")
        app.buttons["保存"].tap()
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "请输入 HTTPS 服务地址")).firstMatch.waitForExistence(timeout: 3))
        app.buttons["取消"].tap()
        XCTAssertTrue(app.staticTexts["从一句你好开始"].exists)
        let capture = XCTAttachment(screenshot: app.screenshot())
        capture.name = "Chat login screen"; capture.lifetime = .keepAlways
        add(capture)
    }
}
