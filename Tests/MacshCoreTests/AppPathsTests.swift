import XCTest
@testable import MacshCore

final class AppPathsTests: XCTestCase {
    func testApplicationSupportCreatesBundleDirectory() throws {
        let id = "com.macsh.tests.\(UUID().uuidString)"
        let dir = try AppPaths.applicationSupport(bundleID: id)
        defer { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(dir.lastPathComponent, id)
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testApplicationSupportIsIdempotent() throws {
        let id = "com.macsh.tests.\(UUID().uuidString)"
        let first = try AppPaths.applicationSupport(bundleID: id)
        defer { try? FileManager.default.removeItem(at: first) }
        XCTAssertEqual(try AppPaths.applicationSupport(bundleID: id), first)
    }
}
