import XCTest
@testable import MacshCore

/// Real servers started by scripts/ci/start-backends.sh: an sshd (password + key auth),
/// an FTP server and an S3 server. Skipped when the MACSH_IT_* variables are absent.
@MainActor
final class BackendIntegrationTests: XCTestCase {
    private let sftpKeys = ["MACSH_IT_SFTP_PORT", "MACSH_IT_SFTP_USER", "MACSH_IT_SFTP_PASS",
                            "MACSH_IT_SFTP_KEY", "MACSH_IT_SFTP_AUTHKEYS", "MACSH_IT_SFTP_DIR"]

    private func sftpEnv() throws -> (port: Int, user: String, pass: String, key: String, authKeys: String, dir: String) {
        let e = try IntegrationEnv.require(sftpKeys[0], sftpKeys[1], sftpKeys[2], sftpKeys[3], sftpKeys[4], sftpKeys[5])
        return (Int(e[sftpKeys[0]]!)!, e[sftpKeys[1]]!, e[sftpKeys[2]]!, e[sftpKeys[3]]!, e[sftpKeys[4]]!, e[sftpKeys[5]]!)
    }

    private func sftpBackend(_ s: (port: Int, user: String, pass: String, key: String, authKeys: String, dir: String),
                             auth: SFTPAuthKind) -> Backend {
        .sftp(SFTPConfig(host: "127.0.0.1", port: s.port, user: s.user, remotePath: s.dir, authKind: auth))
    }

    // MARK: SFTP

    func testSFTPPasswordNFS() async throws {
        let s = try sftpEnv()
        try await IntegrationHarness.roundTrip(
            self, backend: sftpBackend(s, auth: .password),
            secrets: .init(sftp: SFTPSecrets(password: s.pass, privateKeyPath: nil, keyPassphrase: nil)),
            proto: .nfs, label: "sftp-pw-nfs", serverSide: IntegrationHarness.readLocal(s.dir))
    }

    func testSFTPPasswordWebDAV() async throws {
        let s = try sftpEnv()
        try await IntegrationHarness.roundTrip(
            self, backend: sftpBackend(s, auth: .password),
            secrets: .init(sftp: SFTPSecrets(password: s.pass, privateKeyPath: nil, keyPassphrase: nil)),
            proto: .webdav, label: "sftp-pw-dav", serverSide: IntegrationHarness.readLocal(s.dir))
    }

    func testSFTPKeyFile() async throws {
        let s = try sftpEnv()
        try await IntegrationHarness.roundTrip(
            self, backend: sftpBackend(s, auth: .keyFile),
            secrets: .init(sftp: SFTPSecrets(password: nil, privateKeyPath: s.key, keyPassphrase: nil)),
            proto: .nfs, label: "sftp-key", serverSide: IntegrationHarness.readLocal(s.dir))
    }

    /// App-generated key: macsh creates the pair, the server is told the public half,
    /// and the PEM comes back out of the Keychain at mount time.
    func testSFTPGeneratedKey() async throws {
        let s = try sftpEnv()
        let pair = try SSHKeygen.generateEd25519()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: s.authKeys))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((pair.publicKeyOpenSSH + "\n").utf8))
        try handle.close()
        try await IntegrationHarness.roundTrip(
            self, backend: sftpBackend(s, auth: .generatedKey),
            secrets: .init(sftp: SFTPSecrets(password: nil, privateKeyPath: pair.privateKeyPEM, keyPassphrase: nil)),
            proto: .webdav, label: "sftp-gen", serverSide: IntegrationHarness.readLocal(s.dir))
    }

    // MARK: FTP

    private func ftp(_ proto: MountProtocol) async throws {
        let e = try IntegrationEnv.require("MACSH_IT_FTP_PORT", "MACSH_IT_FTP_USER", "MACSH_IT_FTP_PASS", "MACSH_IT_FTP_DIR")
        let backend = Backend.ftp(FTPConfig(host: "127.0.0.1", port: Int(e["MACSH_IT_FTP_PORT"]!)!,
                                            user: e["MACSH_IT_FTP_USER"]!, remotePath: "/", tlsMode: .off))
        try await IntegrationHarness.roundTrip(
            self, backend: backend, secrets: .init(ftp: FTPSecrets(password: e["MACSH_IT_FTP_PASS"]!)),
            proto: proto, label: "ftp-\(proto.rawValue)",
            serverSide: IntegrationHarness.readLocal(e["MACSH_IT_FTP_DIR"]!))
    }

    func testFTPNFS() async throws { try await ftp(.nfs) }
    func testFTPWebDAV() async throws { try await ftp(.webdav) }

    // MARK: S3

    private func s3(_ proto: MountProtocol) async throws {
        let e = try IntegrationEnv.require("MACSH_IT_S3_ENDPOINT", "MACSH_IT_S3_ACCESS", "MACSH_IT_S3_SECRET",
                                           "MACSH_IT_S3_BUCKET", "MACSH_IT_S3_DIR")
        let bucket = e["MACSH_IT_S3_BUCKET"]!
        let backend = Backend.s3(S3Config(provider: .other, region: "us-east-1", endpoint: e["MACSH_IT_S3_ENDPOINT"]!,
                                          bucket: bucket, prefix: ""))
        try await IntegrationHarness.roundTrip(
            self, backend: backend,
            secrets: .init(s3: S3Secrets(accessKeyID: e["MACSH_IT_S3_ACCESS"]!, secretAccessKey: e["MACSH_IT_S3_SECRET"]!)),
            proto: proto, label: "s3-\(proto.rawValue)",
            serverSide: IntegrationHarness.readLocal("\(e["MACSH_IT_S3_DIR"]!)/\(bucket)"))
    }

    func testS3NFS() async throws { try await s3(.nfs) }
    func testS3WebDAV() async throws { try await s3(.webdav) }

    // MARK: Read-only mounts

    func testSFTPReadOnlyRejectsWrites() async throws {
        let s = try sftpEnv()
        try await IntegrationHarness.roundTrip(
            self, backend: sftpBackend(s, auth: .password),
            secrets: .init(sftp: SFTPSecrets(password: s.pass, privateKeyPath: nil, keyPassphrase: nil)),
            proto: .nfs, label: "sftp-ro-nfs", readOnly: true, serverSide: IntegrationHarness.readLocal(s.dir))
        try await IntegrationHarness.roundTrip(
            self, backend: sftpBackend(s, auth: .password),
            secrets: .init(sftp: SFTPSecrets(password: s.pass, privateKeyPath: nil, keyPassphrase: nil)),
            proto: .webdav, label: "sftp-ro-dav", readOnly: true, serverSide: IntegrationHarness.readLocal(s.dir))
    }

    func testFTPReadOnlyRejectsWrites() async throws {
        let e = try IntegrationEnv.require("MACSH_IT_FTP_PORT", "MACSH_IT_FTP_USER", "MACSH_IT_FTP_PASS", "MACSH_IT_FTP_DIR")
        let backend = Backend.ftp(FTPConfig(host: "127.0.0.1", port: Int(e["MACSH_IT_FTP_PORT"]!)!,
                                            user: e["MACSH_IT_FTP_USER"]!, remotePath: "/", tlsMode: .off))
        try await IntegrationHarness.roundTrip(
            self, backend: backend, secrets: .init(ftp: FTPSecrets(password: e["MACSH_IT_FTP_PASS"]!)),
            proto: .nfs, label: "ftp-ro", readOnly: true,
            serverSide: IntegrationHarness.readLocal(e["MACSH_IT_FTP_DIR"]!))
    }

    // MARK: Test connection

    func testConnectionSFTPGoodBadPasswordUnreachableAndBadFolder() async throws {
        let s = try sftpEnv()
        func draft(_ pw: String) -> SessionManager.DraftSecrets {
            .init(sftp: SFTPSecrets(password: pw, privateKeyPath: nil, keyPassphrase: nil))
        }
        let ok = try await IntegrationHarness.connectionTest(self, backend: sftpBackend(s, auth: .password), draft: draft(s.pass))
        XCTAssertTrue(ok.ok, ok.message)

        let bad = try await IntegrationHarness.connectionTest(self, backend: sftpBackend(s, auth: .password), draft: draft("wrong"))
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.message.hasPrefix("Authentication failed"), bad.message)

        let down = Backend.sftp(SFTPConfig(host: "127.0.0.1", port: 1, user: s.user, remotePath: s.dir, authKind: .password))
        let unreachable = try await IntegrationHarness.connectionTest(self, backend: down, draft: draft(s.pass))
        XCTAssertTrue(unreachable.message.hasPrefix("Could not reach the server"), unreachable.message)

        let noDir = Backend.sftp(SFTPConfig(host: "127.0.0.1", port: s.port, user: s.user,
                                            remotePath: s.dir + "/does-not-exist", authKind: .password))
        let missing = try await IntegrationHarness.connectionTest(self, backend: noDir, draft: draft(s.pass))
        XCTAssertTrue(missing.message.hasPrefix("Folder or bucket not found"), missing.message)
    }

    func testConnectionSFTPKeyFile() async throws {
        let s = try sftpEnv()
        let ok = try await IntegrationHarness.connectionTest(
            self, backend: sftpBackend(s, auth: .keyFile),
            draft: .init(sftp: SFTPSecrets(password: nil, privateKeyPath: s.key, keyPassphrase: nil)))
        XCTAssertTrue(ok.ok, ok.message)
    }

    func testConnectionFTPGoodAndBadPassword() async throws {
        let e = try IntegrationEnv.require("MACSH_IT_FTP_PORT", "MACSH_IT_FTP_USER", "MACSH_IT_FTP_PASS")
        let backend = Backend.ftp(FTPConfig(host: "127.0.0.1", port: Int(e["MACSH_IT_FTP_PORT"]!)!,
                                            user: e["MACSH_IT_FTP_USER"]!, remotePath: "/", tlsMode: .off))
        let ok = try await IntegrationHarness.connectionTest(self, backend: backend,
                                                             draft: .init(ftp: FTPSecrets(password: e["MACSH_IT_FTP_PASS"]!)))
        XCTAssertTrue(ok.ok, ok.message)
        let bad = try await IntegrationHarness.connectionTest(self, backend: backend,
                                                              draft: .init(ftp: FTPSecrets(password: "wrong")))
        XCTAssertTrue(bad.message.hasPrefix("Authentication failed"), bad.message)
    }

    func testConnectionS3GoodBadSecretAndMissingBucket() async throws {
        let e = try IntegrationEnv.require("MACSH_IT_S3_ENDPOINT", "MACSH_IT_S3_ACCESS", "MACSH_IT_S3_SECRET", "MACSH_IT_S3_BUCKET")
        func backend(bucket: String) -> Backend {
            .s3(S3Config(provider: .other, region: "us-east-1", endpoint: e["MACSH_IT_S3_ENDPOINT"]!, bucket: bucket, prefix: ""))
        }
        let good = SessionManager.DraftSecrets(s3: S3Secrets(accessKeyID: e["MACSH_IT_S3_ACCESS"]!, secretAccessKey: e["MACSH_IT_S3_SECRET"]!))
        let ok = try await IntegrationHarness.connectionTest(self, backend: backend(bucket: e["MACSH_IT_S3_BUCKET"]!), draft: good)
        XCTAssertTrue(ok.ok, ok.message)

        let badSecret = SessionManager.DraftSecrets(s3: S3Secrets(accessKeyID: e["MACSH_IT_S3_ACCESS"]!, secretAccessKey: "wrong"))
        let bad = try await IntegrationHarness.connectionTest(self, backend: backend(bucket: e["MACSH_IT_S3_BUCKET"]!), draft: badSecret)
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.message.hasPrefix("Authentication failed"), bad.message)

        let missing = try await IntegrationHarness.connectionTest(self, backend: backend(bucket: "no-such-bucket"), draft: good)
        XCTAssertFalse(missing.ok)
        XCTAssertTrue(missing.message.hasPrefix("Folder or bucket not found"), missing.message)
    }

    // MARK: Import from rclone.conf

    /// A rclone.conf with real `rclone obscure`d passwords is imported through macsh, edited
    /// (rclone.conf has no remote path) and then mounted against the real servers.
    func testImportFromRcloneConfThenMountEachBackend() async throws {
        let s = try sftpEnv()
        let f = try IntegrationEnv.require("MACSH_IT_FTP_PORT", "MACSH_IT_FTP_USER", "MACSH_IT_FTP_PASS", "MACSH_IT_FTP_DIR")
        let e = try IntegrationEnv.require("MACSH_IT_S3_ENDPOINT", "MACSH_IT_S3_ACCESS", "MACSH_IT_S3_SECRET",
                                           "MACSH_IT_S3_BUCKET", "MACSH_IT_S3_DIR")
        let rclone = try RcloneBinary.resolve()
        let sftpPass = try RcloneProcess.obscure(plaintext: s.pass, binary: rclone)
        let ftpPass = try RcloneProcess.obscure(plaintext: f["MACSH_IT_FTP_PASS"]!, binary: rclone)
        let conf = """
        [it-sftp]
        type = sftp
        host = 127.0.0.1
        port = \(s.port)
        user = \(s.user)
        pass = \(sftpPass)

        [it-ftp]
        type = ftp
        host = 127.0.0.1
        port = \(f["MACSH_IT_FTP_PORT"]!)
        user = \(f["MACSH_IT_FTP_USER"]!)
        pass = \(ftpPass)

        [it-s3]
        type = s3
        provider = Other
        access_key_id = \(e["MACSH_IT_S3_ACCESS"]!)
        secret_access_key = \(e["MACSH_IT_S3_SECRET"]!)
        endpoint = \(e["MACSH_IT_S3_ENDPOINT"]!)

        [it-crypt]
        type = crypt
        remote = it-sftp:
        """

        let dir = try makeTempDir()
        let manager = SessionManager(
            store: RemoteStore(directory: dir), keychain: KeychainService(serviceName: "macsh.it.\(UUID().uuidString)"),
            mounter: Mounter(), logsDir: dir.appendingPathComponent("logs"), rcloneBinary: rclone)
        addTeardownBlock { @MainActor in
            manager.shutdownAll()
            for session in manager.sessions { try? manager.delete(session.id) }
            try? FileManager.default.removeItem(at: dir)
        }

        let summary = await manager.importRemotes(RcloneConfParser.parse(conf), defaultProtocol: .webdav,
                                                  buckets: ["it-s3": e["MACSH_IT_S3_BUCKET"]!])
        XCTAssertEqual(summary.imported, ["it-sftp", "it-ftp", "it-s3"])
        XCTAssertEqual(summary.skipped.map(\.name), ["it-crypt"])

        func remote(_ name: String) throws -> Remote {
            try XCTUnwrap(manager.sessions.first { $0.remote.name == name }).remote
        }

        // SFTP: point the imported remote at the fixture directory, as a user would in Edit.
        var sftp = try remote("it-sftp")
        sftp.backend = .sftp(SFTPConfig(host: "127.0.0.1", port: s.port, user: s.user, remotePath: s.dir, authKind: .password))
        try manager.update(sftp)
        try await IntegrationHarness.verifyRoundTrip(manager: manager, remote: sftp, label: "import-sftp",
                                                     serverSide: IntegrationHarness.readLocal(s.dir))
        try await IntegrationHarness.verifyRoundTrip(manager: manager, remote: try remote("it-ftp"), label: "import-ftp",
                                                     serverSide: IntegrationHarness.readLocal(f["MACSH_IT_FTP_DIR"]!))
        try await IntegrationHarness.verifyRoundTrip(
            manager: manager, remote: try remote("it-s3"), label: "import-s3",
            serverSide: IntegrationHarness.readLocal("\(e["MACSH_IT_S3_DIR"]!)/\(e["MACSH_IT_S3_BUCKET"]!)"))
    }

    // MARK: SMB

    private func smbBackend(port: String, user: String, share: String) -> Backend {
        .rclone(BackendDescriptor.smb.makeConfig(
            values: ["host": "127.0.0.1", "port": port, "user": user], remotePath: share))
    }

    private func smb(_ proto: MountProtocol) async throws {
        let e = try IntegrationEnv.require("MACSH_IT_SMB_PORT", "MACSH_IT_SMB_USER", "MACSH_IT_SMB_PASS",
                                           "MACSH_IT_SMB_SHARE", "MACSH_IT_SMB_DIR")
        try await IntegrationHarness.roundTrip(
            self, backend: smbBackend(port: e["MACSH_IT_SMB_PORT"]!, user: e["MACSH_IT_SMB_USER"]!, share: e["MACSH_IT_SMB_SHARE"]!),
            secrets: .init(options: ["pass": e["MACSH_IT_SMB_PASS"]!]), proto: proto,
            label: "smb-\(proto.rawValue)", serverSide: IntegrationHarness.readLocal(e["MACSH_IT_SMB_DIR"]!))
    }

    func testSMBNFS() async throws { try await smb(.nfs) }
    func testSMBWebDAV() async throws { try await smb(.webdav) }

    func testConnectionSMBGoodBadPasswordUnreachableAndMissingShare() async throws {
        let e = try IntegrationEnv.require("MACSH_IT_SMB_PORT", "MACSH_IT_SMB_USER", "MACSH_IT_SMB_PASS", "MACSH_IT_SMB_SHARE")
        let good = smbBackend(port: e["MACSH_IT_SMB_PORT"]!, user: e["MACSH_IT_SMB_USER"]!, share: e["MACSH_IT_SMB_SHARE"]!)
        let ok = try await IntegrationHarness.connectionTest(self, backend: good, draft: .init(options: ["pass": e["MACSH_IT_SMB_PASS"]!]))
        XCTAssertTrue(ok.ok, "\(ok.message) | \(ok.detail)")

        let bad = try await IntegrationHarness.connectionTest(self, backend: good, draft: .init(options: ["pass": "wrong"]))
        XCTAssertFalse(bad.ok)
        XCTAssertTrue(bad.message.hasPrefix("Authentication failed"), "\(bad.message) | \(bad.detail)")

        let down = smbBackend(port: "1", user: e["MACSH_IT_SMB_USER"]!, share: e["MACSH_IT_SMB_SHARE"]!)
        let unreachable = try await IntegrationHarness.connectionTest(self, backend: down, draft: .init(options: ["pass": "x"]))
        XCTAssertTrue(unreachable.message.hasPrefix("Could not reach the server"), "\(unreachable.message) | \(unreachable.detail)")

        let noShare = smbBackend(port: e["MACSH_IT_SMB_PORT"]!, user: e["MACSH_IT_SMB_USER"]!, share: "no-such-share")
        let missing = try await IntegrationHarness.connectionTest(self, backend: noShare, draft: .init(options: ["pass": e["MACSH_IT_SMB_PASS"]!]))
        XCTAssertTrue(missing.message.hasPrefix("Folder or bucket not found"), "\(missing.message) | \(missing.detail)")
    }
}
