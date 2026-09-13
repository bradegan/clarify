import XCTest
@testable import ClarifyKit

final class RemoteCommandTests: XCTestCase {
    func testRoutes() {
        XCTAssertEqual(RemoteCommand.parse(URL(string: "clarify://process")!), .process)
        XCTAssertEqual(RemoteCommand.parse(URL(string: "clarify://process/existing")!), .processExisting)
        XCTAssertEqual(RemoteCommand.parse(URL(string: "clarify://review/weekly")!), .weeklyReview)
        XCTAssertEqual(RemoteCommand.parse(URL(string: "clarify://sweep/daily")!), .dailySweep)
        XCTAssertEqual(RemoteCommand.parse(URL(string: "clarify://mail/check")!), .checkMail)
        XCTAssertEqual(RemoteCommand.parse(URL(string: "clarify://engage?q=twenty%20minutes")!), .engage("twenty minutes"))
        XCTAssertNil(RemoteCommand.parse(URL(string: "clarify://delete/everything")!))
        XCTAssertNil(RemoteCommand.parse(URL(string: "https://example.com/process")!))
    }
}
