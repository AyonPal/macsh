import XCTest
@testable import MacshCore

final class UserPreferencesTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "macsh.tests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    func testDefaultProtocolFallsBackToWebDAV() {
        XCTAssertEqual(UserPreferences(defaults: defaults).defaultProtocol, .webdav)
    }

    func testDefaultProtocolPersists() {
        let prefs = UserPreferences(defaults: defaults)
        prefs.defaultProtocol = .nfs
        XCTAssertEqual(UserPreferences(defaults: defaults).defaultProtocol, .nfs)
    }

    func testInvalidStoredProtocolFallsBack() {
        defaults.set("bogus", forKey: "macsh.defaultProtocol")
        XCTAssertEqual(UserPreferences(defaults: defaults).defaultProtocol, .webdav)
    }

    func testCustomRclonePathDefaultsToNil() {
        XCTAssertNil(UserPreferences(defaults: defaults).customRclonePath)
    }

    func testCustomRclonePathIsTrimmed() {
        let prefs = UserPreferences(defaults: defaults)
        prefs.customRclonePath = "  /usr/local/bin/rclone \n"
        XCTAssertEqual(prefs.customRclonePath, "/usr/local/bin/rclone")
    }

    func testBlankOrNilClearsCustomRclonePath() {
        let prefs = UserPreferences(defaults: defaults)
        prefs.customRclonePath = "/x"
        prefs.customRclonePath = "   "
        XCTAssertNil(prefs.customRclonePath)
        prefs.customRclonePath = "/x"
        prefs.customRclonePath = nil
        XCTAssertNil(prefs.customRclonePath)
    }
}
