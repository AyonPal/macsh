import XCTest
@testable import MacshCore

final class SmokeTest: XCTestCase {
    func testVersionExposed() {
        XCTAssertEqual(MacshCore.version, "0.1.0-phase1")
    }
}
