import XCTest
@testable import MacshCore

final class MounterTests: XCTestCase {
    func testVolumeNameStripsIllegalCharacters() {
        let m = Mounter()
        XCTAssertEqual(m.volumeName(from: "my/server"), "my-server")
        XCTAssertEqual(m.volumeName(from: "a:b"), "a-b")
        XCTAssertEqual(m.volumeName(from: "  padded  "), "padded")
        XCTAssertEqual(m.volumeName(from: "nul\0byte"), "nulbyte")
        XCTAssertEqual(m.volumeName(from: "My Laptop"), "My Laptop")
    }

    func testVolumeNameFallsBackWhenEmpty() {
        let m = Mounter()
        XCTAssertEqual(m.volumeName(from: ""), "macsh-mount")
        XCTAssertEqual(m.volumeName(from: "   "), "macsh-mount")
    }

    func testErrorDescriptions() {
        typealias E = Mounter.MountError
        XCTAssertEqual(E.mountpointCreationFailed("nope").errorDescription, "Could not create mountpoint: nope")
        XCTAssertEqual(E.mountFailed(stderr: "bad", exitCode: 2).errorDescription, "mount failed (exit 2): bad")
        XCTAssertEqual(E.mountFailed(stderr: "", exitCode: 1).errorDescription, "mount failed (exit 1): no stderr output")
        XCTAssertEqual(E.unmountFailed(stderr: "busy", exitCode: 1).errorDescription, "unmount failed (exit 1): busy")
        XCTAssertEqual(E.unmountFailed(stderr: "", exitCode: 3).errorDescription, "unmount failed (exit 3): no stderr output")
        XCTAssertEqual(E.netFSFailed(status: 5).errorDescription, "NetFS mount failed (status 5)")
    }

    func testReconcileStaleMountIgnoresUnmountedVolume() {
        XCTAssertFalse(Mounter().reconcileStaleMount(volumeName: "macsh-test-\(UUID().uuidString)"))
    }

    func testUnmountOfNonMountedPathIsSuccess() {
        let path = "/nonexistent/macsh-\(UUID().uuidString)"
        XCTAssertFalse(Mounter().isMounted(mountpoint: path))
        XCTAssertNoThrow(try Mounter().unmount(mountpoint: path))
    }

    func testMountNFSToBogusMountpointThrows() {
        XCTAssertThrowsError(
            try Mounter().mountNFS(host: "127.0.0.1", port: 1, exportPath: "/", name: "x",
                                   mountpoint: "/nonexistent/macsh-\(UUID().uuidString)")
        ) { error in
            guard case Mounter.MountError.mountFailed = error else {
                return XCTFail("expected mountFailed, got \(error)")
            }
        }
    }
}
