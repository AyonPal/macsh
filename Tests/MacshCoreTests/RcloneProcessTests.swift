import XCTest
@testable import MacshCore

final class RcloneProcessTests: XCTestCase {
    private func fixture() throws -> (FakeRclone, RcloneProcess, URL) {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let fake = try FakeRclone.make(in: dir)
        let runner = RcloneProcess(binary: fake.binary, logFile: dir.appendingPathComponent("rclone.log"))
        return (fake, runner, dir)
    }

    func testObscureReturnsBinaryOutput() throws {
        let (fake, _, _) = try fixture()
        XCTAssertEqual(try RcloneProcess.obscure(plaintext: "secret", binary: fake.binary), "OBS-secret")
    }

    func testSpawnWebDAVServeBuildsArguments() throws {
        let (fake, runner, dir) = try fixture()
        let spawned = try runner.spawnWebDAVServe(
            remoteName: "r", remotePath: "/data", configText: "[r]\ntype = sftp\n",
            baseurl: "/vol", liveUpdates: true, envOverrides: ["MACSH_TEST_ENV": "hello"]
        )
        defer { spawned.process.terminate() }

        let lines = fake.recordedLines()
        XCTAssertEqual(Array(lines.prefix(3)), ["serve", "webdav", "r:/data"])
        XCTAssertTrue(lines.contains("--addr"))
        XCTAssertTrue(lines.contains("127.0.0.1:\(spawned.port)"))
        XCTAssertTrue(lines.contains("--baseurl"))
        XCTAssertTrue(lines.contains("/vol"))
        XCTAssertTrue(lines.contains("--dir-cache-time"))
        XCTAssertTrue(lines.contains("--vfs-fast-fingerprint"))
        XCTAssertTrue(lines.contains("--user"))
        XCTAssertTrue(lines.contains(spawned.user))
        XCTAssertTrue(lines.contains(spawned.password))
        XCTAssertTrue(lines.contains("ENV:MACSH_TEST_ENV=hello"))
        XCTAssertGreaterThan(spawned.port, 0)
        XCTAssertTrue(spawned.user.hasPrefix("macsh-"))

        // The config text is written to the file passed via --config.
        let cfgIdx = try XCTUnwrap(lines.firstIndex(of: "--config"))
        let cfg = try String(contentsOfFile: lines[cfgIdx + 1], encoding: .utf8)
        XCTAssertEqual(cfg, "[r]\ntype = sftp\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("rclone.log").path))
    }

    func testWebDAVWithoutLiveUpdatesOmitsCacheFlags() throws {
        let (fake, runner, _) = try fixture()
        let spawned = try runner.spawnWebDAVServe(
            remoteName: "r", remotePath: "/", configText: "[r]\n", baseurl: "/v", liveUpdates: false
        )
        defer { spawned.process.terminate() }
        let lines = fake.recordedLines()
        XCTAssertFalse(lines.contains("--dir-cache-time"))
        XCTAssertFalse(lines.contains("--vfs-fast-fingerprint"))
        XCTAssertTrue(lines.contains("--vfs-cache-mode"))
    }

    func testSpawnNFSServeHasNoAuth() throws {
        let (fake, runner, _) = try fixture()
        let spawned = try runner.spawnNFSServe(
            remoteName: "r", remotePath: "bucket/prefix", configText: "[r]\n", liveUpdates: true
        )
        defer { spawned.process.terminate() }
        let lines = fake.recordedLines()
        XCTAssertEqual(Array(lines.prefix(3)), ["serve", "nfs", "r:bucket/prefix"])
        XCTAssertFalse(lines.contains("--user"))
        XCTAssertFalse(lines.contains("--baseurl"))
        XCTAssertTrue(lines.contains("--dir-cache-time"))
        XCTAssertEqual(spawned.user, "")
        XCTAssertEqual(spawned.password, "")
    }

    func testSpawnDistinctPorts() throws {
        let (_, runner, _) = try fixture()
        let a = try runner.spawnNFSServe(remoteName: "r", remotePath: "/", configText: "[r]\n", liveUpdates: false)
        defer { a.process.terminate() }
        XCTAssertGreaterThan(a.port, 1023)
    }

    func testLaunchFailureThrows() throws {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let runner = RcloneProcess(
            binary: URL(fileURLWithPath: "/nonexistent/rclone"),
            logFile: dir.appendingPathComponent("rclone.log")
        )
        XCTAssertThrowsError(
            try runner.spawnNFSServe(remoteName: "r", remotePath: "/", configText: "[r]\n", liveUpdates: false)
        ) { error in
            guard case RcloneProcess.SpawnError.launchFailed = error else {
                return XCTFail("expected launchFailed, got \(error)")
            }
        }
    }
}
