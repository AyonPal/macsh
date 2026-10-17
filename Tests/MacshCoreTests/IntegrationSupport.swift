import XCTest
@testable import MacshCore

/// Shared driver for the env-gated integration tests. They exercise macsh's own pipeline
/// (SessionManager -> RcloneConfigBuilder -> RcloneProcess -> Mounter), not the rclone CLI
/// directly: add the remote, mount it for real, write a file through the mount and check
/// the file reached the server side. rclone (the engine macsh wraps) is a real binary.
enum IntegrationEnv {
    /// Returns the values of `keys`, or skips the test when any is unset.
    static func require(_ keys: String...) throws -> [String: String] {
        let env = ProcessInfo.processInfo.environment
        var out: [String: String] = [:]
        for k in keys {
            guard let v = env[k], !v.isEmpty else { throw XCTSkip("\(k) not set (integration server not running)") }
            out[k] = v
        }
        return out
    }
}

@MainActor
enum IntegrationHarness {
    struct Secrets {
        var sftp: SFTPSecrets?
        var s3: S3Secrets?
        var ftp: FTPSecrets?
        var options: [String: String]?
        init(sftp: SFTPSecrets? = nil, s3: S3Secrets? = nil, ftp: FTPSecrets? = nil, options: [String: String]? = nil) {
            self.sftp = sftp; self.s3 = s3; self.ftp = ftp; self.options = options
        }
    }

    /// Mounts `backend` over `proto`, writes a file, and waits for `serverSide(fileName)`
    /// to return the same content. Then unmounts.
    static func roundTrip(
        _ test: XCTestCase,
        backend: Backend,
        secrets: Secrets,
        proto: MountProtocol,
        label: String,
        readOnly: Bool = false,
        serverSide: @escaping (String) async -> String?
    ) async throws {
        let rclone = try RcloneBinary.resolve()
        let dir = try makeTempDir()
        let manager = SessionManager(
            store: RemoteStore(directory: dir),
            keychain: KeychainService(serviceName: "macsh.it.\(UUID().uuidString)"),
            mounter: Mounter(),
            logsDir: dir.appendingPathComponent("logs"),
            rcloneBinary: rclone
        )
        let remote = Remote(id: UUID(), name: "macsh-it-\(label)-\(Int.random(in: 1000...9999))",
                            backend: backend, mountProtocol: proto, autoMount: false, readOnly: readOnly)
        try manager.add(remote, sftpSecrets: secrets.sftp, s3Secrets: secrets.s3,
                        ftpSecrets: secrets.ftp, optionSecrets: secrets.options)
        test.addTeardownBlock { @MainActor in
            manager.shutdownAll()
            try? manager.delete(remote.id)
            try? FileManager.default.removeItem(at: dir)
        }

        try await verifyRoundTrip(manager: manager, remote: remote, label: label,
                                  readOnly: readOnly, serverSide: serverSide)
    }

    /// Mount `remote` (already added to `manager`), write a file through the mount, wait for
    /// `serverSide` to see it (or, when read-only, to never see it), then unmount.
    static func verifyRoundTrip(
        manager: SessionManager, remote: Remote, label: String, readOnly: Bool = false,
        serverSide: @escaping (String) async -> String?
    ) async throws {
        let session = try XCTUnwrap(manager.sessions.first { $0.id == remote.id })
        try await manager.mount(remoteID: remote.id)
        guard case .mounted(let mountpoint) = session.status else {
            return XCTFail("\(label): not mounted: \(session.status)")
        }

        let fileName = "macsh-\(label)-\(UUID().uuidString).txt"
        let payload = "hello from macsh \(UUID().uuidString)"

        if readOnly {
            // Writes must be rejected and nothing may reach the server.
            XCTAssertThrowsError(try payload.write(toFile: "\(mountpoint)/\(fileName)", atomically: false, encoding: .utf8),
                                 "\(label): write succeeded on a read-only mount")
            try await Task.sleep(nanoseconds: 3_000_000_000)
            let leaked = await serverSide(fileName)
            XCTAssertNil(leaked, "\(label): file reached the server from a read-only mount")
            try await manager.unmount(remoteID: remote.id)
            return
        }

        try payload.write(toFile: "\(mountpoint)/\(fileName)", atomically: false, encoding: .utf8)
        XCTAssertEqual(try String(contentsOfFile: "\(mountpoint)/\(fileName)", encoding: .utf8), payload)

        // Writes pass through rclone's write-back cache; they must reach the server.
        var seen: String?
        for _ in 0..<40 {
            seen = await serverSide(fileName)
            if seen == payload { break }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertEqual(seen, payload, "\(label): file written through the mount never reached the server")

        try await manager.unmount(remoteID: remote.id)
        XCTAssertEqual(session.status, .idle)
    }

    /// Server-side check for backends whose storage is a local directory.
    static func readLocal(_ dir: String) -> (String) async -> String? {
        { name in try? String(contentsOfFile: "\(dir)/\(name)", encoding: .utf8) }
    }
}

extension IntegrationHarness {
    /// "Test connection" against a real server, with the secrets as typed in the form.
    static func connectionTest(
        _ test: XCTestCase, backend: Backend, draft: SessionManager.DraftSecrets
    ) async throws -> ConnectionTestResult {
        let dir = try makeTempDir()
        test.addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let manager = SessionManager(
            store: RemoteStore(directory: dir),
            keychain: KeychainService(serviceName: "macsh.it.\(UUID().uuidString)"),
            mounter: Mounter(), logsDir: dir.appendingPathComponent("logs"),
            rcloneBinary: try RcloneBinary.resolve())
        let remote = Remote(id: UUID(), name: "macsh-it-test", backend: backend,
                            mountProtocol: .webdav, autoMount: false)
        return await manager.testConnection(remote, draft: draft)
    }
}
