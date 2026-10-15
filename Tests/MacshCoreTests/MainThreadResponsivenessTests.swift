import XCTest
@testable import MacshCore

/// The menu bar item is driven by the main thread. mount/unmount used to run their
/// blocking work (rclone obscure, ssh-keyscan, waiting for the port, NetFS, mount_nfs)
/// on it, so the item was unclickable for the whole duration.
@MainActor
final class MainThreadResponsivenessTests: XCTestCase {
    private var dir: URL!
    private let id = UUID(uuidString: "44444444-4444-4444-4444-444444444444")!
    private let keychain = KeychainService(serviceName: "ai.macsh.test")

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-resp-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? keychain.delete(remoteID: id, kind: .password)
        try? FileManager.default.removeItem(at: dir)
    }

    /// A stand-in for rclone: `obscure` takes 1s, `serve` runs but never listens.
    private func fakeRclone() throws -> URL {
        let url = dir.appendingPathComponent("rclone")
        try """
        #!/bin/sh
        if [ "$1" = "obscure" ]; then sleep 1; echo obscured; exit 0; fi
        sleep 20
        """.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    private func makeManager() throws -> SessionManager {
        let store = RemoteStore(directory: dir)
        try store.save([Remote(
            id: id, name: "slow",
            backend: .ftp(FTPConfig(host: "h", port: 21, user: "u", remotePath: "", tlsMode: .off)),
            mountProtocol: .webdav, autoMount: false
        )])
        try keychain.set(remoteID: id, kind: .password, value: "pw")
        let m = SessionManager(store: store, keychain: keychain, mounter: Mounter(),
                               logsDir: dir.appendingPathComponent("logs"), rcloneBinary: try fakeRclone())
        m.portWaitTimeout = 2
        try m.reload()
        return m
    }

    func testMainThreadStaysResponsiveDuringSlowMount() async throws {
        let manager = try makeManager()

        var maxGap: TimeInterval = 0
        var last = Date()
        var ticks = 0
        var running = true
        let heartbeat = Task { @MainActor in
            while running {
                let now = Date()
                maxGap = max(maxGap, now.timeIntervalSince(last))
                last = now
                ticks += 1
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
        }

        let started = Date()
        do { try await manager.mount(remoteID: id); XCTFail("mount should have failed") }
        catch { /* expected: fake rclone never listens */ }
        let elapsed = Date().timeIntervalSince(started)
        running = false
        await heartbeat.value
        maxGap = max(maxGap, Date().timeIntervalSince(last))   // a heartbeat starved to death still counts

        print("mount took \(String(format: "%.1f", elapsed))s, main-thread max stall \(String(format: "%.2f", maxGap))s over \(ticks) ticks")
        XCTAssertGreaterThan(elapsed, 2.5, "the slow work really happened")
        XCTAssertGreaterThan(ticks, 20, "main run loop barely ran (\(ticks) ticks)")
        XCTAssertLessThan(maxGap, 0.5, "main thread was blocked for \(maxGap)s")
    }

    func testSecondMountWhileStartingIsIgnored() async throws {
        let manager = try makeManager()
        async let first: Void = { try? await manager.mount(remoteID: id) }()
        try await Task.sleep(nanoseconds: 200_000_000)
        let t = Date()
        try await manager.mount(remoteID: id)          // returns immediately, no second rclone
        XCTAssertLessThan(Date().timeIntervalSince(t), 0.5)
        await first
    }
}
