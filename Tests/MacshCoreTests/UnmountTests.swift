import XCTest
@testable import MacshCore

final class UnmountTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-unmount-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testPlainDirectoryIsNotMounted() {
        XCTAssertFalse(Mounter().isMounted(mountpoint: dir.path))
    }

    func testRootIsMounted() {
        XCTAssertTrue(Mounter().isMounted(mountpoint: "/"))
    }

    func testUnmountOfAlreadyUnmountedPathSucceeds() throws {
        // Previously this threw "Unmount failed for <path>" and left the session stuck.
        XCTAssertNoThrow(try Mounter().unmount(mountpoint: dir.path))
    }

    func testUnmountOfMissingPathSucceeds() {
        XCTAssertNoThrow(try Mounter().unmount(mountpoint: dir.appendingPathComponent("gone").path))
    }
}
