import XCTest

/// Drives the real app window with an in-memory store and a deterministic model.
/// On macOS, SwiftUI static text exposes its string through `value`, not `label`.
final class EngageUITests: XCTestCase {
    func testEngageFiltersSeededActionsAndStages() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTest"]
        app.launch()

        let field = app.textFields["engageField"]
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.click()
        field.typeText("twenty minutes low energy @phone")
        app.buttons["engageFind"].click()

        let status = app.staticTexts["engageStatus"]
        expectation(for: NSPredicate(format: "value CONTAINS 'candidate'"), evaluatedWith: status)
        waitForExpectations(timeout: 10)
        XCTAssertEqual(status.value as? String, "2 candidates",
                       "only the short low-energy phone call and the anywhere stretch fit; daemon says: \(app.staticTexts["daemonStatus"].value ?? "nil")")

        let stage = app.buttons["engageStage"]
        XCTAssertTrue(stage.isEnabled)
        stage.click()
        expectation(for: NSPredicate(format: "isEnabled == false"), evaluatedWith: stage)
        waitForExpectations(timeout: 5)
    }
}
