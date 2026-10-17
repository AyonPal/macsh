import XCTest
@testable import MacshCore

final class StaleMountTests: XCTestCase {
    private let mountOutput = """
    /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
    127.0.0.1:/ on /Users/fco/macsh/DevEnv (nfs, nodev, nosuid, mounted by fco)
    127.0.0.1:/ on /Users/fco/macsh/DevEnv-2 (nfs, nodev, nosuid, mounted by fco)
    http://127.0.0.1:49165/Docs/ on /Volumes/Docs (webdav, nodev, nosuid, mounted by fco)
    192.168.1.5:/export on /Users/fco/macsh/Nas (nfs, nodev, nosuid, mounted by fco)
    127.0.0.1:/ on /Users/fco/other/Thing (nfs, nodev, nosuid, mounted by fco)
    /dev/disk4s1 on /Volumes/macsh (hfs, local, nodev, nosuid, read-only, noowners, quarantine, mounted by fco)
    """

    private let nfsstat = """
    /Users/fco/macsh/DevEnv from 127.0.0.1:/
      -s sys
      NFS parameters: vers=3,tcp,port=54924,mountport=54924,soft,noresvport,nolocks,rsize=1048576
      File system locations:
        /
    /Users/fco/macsh/DevEnv-2 from 127.0.0.1:/
      NFS parameters: vers=3,tcp,port=55300,mountport=55300,soft,noresvport,nolocks
    """

    func testFindsOnlyLocalRcloneMounts() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstat, mountBase: "/Users/fco/macsh")
        XCTAssertEqual(found.map(\.path), ["/Users/fco/macsh/DevEnv", "/Users/fco/macsh/DevEnv-2", "/Volumes/Docs"])
    }

    func testNFSPortsComeFromNfsstat() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstat, mountBase: "/Users/fco/macsh")
        XCTAssertEqual(found[0].port, 54924)
        XCTAssertEqual(found[1].port, 55300)
        XCTAssertEqual(found[0].kind, .nfs)
    }

    func testWebDAVPortComesFromTheURL() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstat, mountBase: "/Users/fco/macsh")
        XCTAssertEqual(found[2].kind, .webdav)
        XCTAssertEqual(found[2].port, 49165)
    }

    func testIgnoresRemoteNFSAndMountsOutsideTheBase() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: nfsstat, mountBase: "/Users/fco/macsh")
        XCTAssertFalse(found.contains { $0.path.hasSuffix("Nas") || $0.path.hasSuffix("Thing") })
    }

    func testMissingNfsstatLeavesPortUnknown() {
        let found = Mounter.parseLocalMounts(mountOutput: mountOutput, nfsstatOutput: "", mountBase: "/Users/fco/macsh")
        XCTAssertNil(found.first?.port)
    }

    func testBaseWithTrailingSlashAndPrefixLookalike() {
        let text = "127.0.0.1:/ on /Users/fco/macsh-other/X (nfs, nodev)\n127.0.0.1:/ on /Users/fco/macsh/Y (nfs, nodev)"
        let found = Mounter.parseLocalMounts(mountOutput: text, nfsstatOutput: "", mountBase: "/Users/fco/macsh/")
        XCTAssertEqual(found.map(\.path), ["/Users/fco/macsh/Y"])
    }

    func testForceUnmountOfUnmountedPathIsNoOp() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("macsh-fu-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNoThrow(try Mounter().forceUnmount(mountpoint: dir.path))
    }
}

@MainActor
final class RcloneExitWatcherTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("macsh-exit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func makeSession(autoMount: Bool = false) -> (SessionManager, RemoteSession) {
        let remote = Remote(
            id: UUID(), name: "w",
            backend: .ftp(FTPConfig(host: "h", port: 21, user: "u", remotePath: "", tlsMode: .off)),
            mountProtocol: .nfs, autoMount: autoMount
        )
        let manager = SessionManager(
            store: RemoteStore(directory: dir), keychain: KeychainService(serviceName: "ai.macsh.test"),
            mounter: Mounter(mountBase: dir), logsDir: dir.appendingPathComponent("logs"),
            rcloneBinary: URL(fileURLWithPath: "/usr/bin/true"))
        return (manager, RemoteSession(remote: remote))
    }

    private func finishedProcess(status: Int32) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "exit \(status)"]
        try p.run(); p.waitUntilExit()
        return p
    }

    func testUnexpectedExitMarksFailedAndClearsMount() async throws {
        let (manager, session) = makeSession()
        let proc = try finishedProcess(status: 7)
        session.rcloneProcess = proc
        session.mountpoint = dir.path            // not a real mount: force-unmount is a no-op
        session.transition(to: .mounted(at: dir.path))
        await manager.handleRcloneExit(session: session, process: proc)
        guard case .failed(let reason) = session.status else { return XCTFail("expected failed, got \(session.status)") }
        XCTAssertTrue(reason.contains("exit 7"))
        XCTAssertNil(session.mountpoint)
        XCTAssertNil(session.rcloneProcess)
    }

    func testIntentionalStopIsIgnored() async throws {
        let (manager, session) = makeSession()
        let proc = try finishedProcess(status: 0)
        session.rcloneProcess = nil              // unmount detaches the process before terminating it
        session.transition(to: .idle)
        await manager.handleRcloneExit(session: session, process: proc)
        XCTAssertEqual(session.status, .idle)
    }

    func testExitDuringStoppingIsIgnored() async throws {
        let (manager, session) = makeSession()
        let proc = try finishedProcess(status: 0)
        session.rcloneProcess = proc
        session.transition(to: .stopping)
        await manager.handleRcloneExit(session: session, process: proc)
        XCTAssertEqual(session.status, .stopping)
    }
}
