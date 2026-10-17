import XCTest
@testable import MacshCore

final class RcloneBinaryTests: XCTestCase {
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

    func testCustomPathTakesPriority() throws {
        let prefs = UserPreferences(defaults: defaults)
        prefs.customRclonePath = "/bin/sh"
        let url = try RcloneBinary.resolve(prefs: prefs, env: ["RCLONE_PATH": "/bin/ls"])
        XCTAssertEqual(url.path, "/bin/sh")
    }

    func testEnvOverrideUsedWhenNoCustomPath() throws {
        let url = try RcloneBinary.resolve(prefs: UserPreferences(defaults: defaults), env: ["RCLONE_PATH": "/bin/ls"])
        XCTAssertEqual(url.path, "/bin/ls")
    }

    func testNonExecutableCustomPathFallsThroughToEnv() throws {
        let prefs = UserPreferences(defaults: defaults)
        prefs.customRclonePath = "/nonexistent/rclone"
        let url = try RcloneBinary.resolve(prefs: prefs, env: ["RCLONE_PATH": "/bin/ls"])
        XCTAssertEqual(url.path, "/bin/ls")
    }

    func testNotFoundErrorListsSearchedPaths() {
        // Skip when a real rclone happens to be installed at a fallback location.
        let fallbacks = ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"]
        guard !fallbacks.contains(where: { FileManager.default.isExecutableFile(atPath: $0) }) else { return }

        let prefs = UserPreferences(defaults: defaults)
        prefs.customRclonePath = "/nonexistent/rclone"
        XCTAssertThrowsError(try RcloneBinary.resolve(prefs: prefs, bundle: Bundle(for: Self.self), env: [:])) { error in
            guard case RcloneBinaryError.notFound(let paths) = error else {
                return XCTFail("expected notFound, got \(error)")
            }
            XCTAssertTrue(paths.contains("/nonexistent/rclone"))
            XCTAssertTrue(paths.contains("/usr/local/bin/rclone"))
            XCTAssertTrue("\(error)".contains("brew install rclone"))
        }
    }
}
