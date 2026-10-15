import XCTest
@testable import MacshCore

final class RcloneConfigBuilderTests: XCTestCase {
    func testSFTPPasswordAuthBasic() throws {
        let r = Remote(
            id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!,
            name: "myhost",
            backend: .sftp(SFTPConfig(host: "example.com", port: 22, user: "alice", remotePath: "/", authKind: .password)),
            mountProtocol: .webdav, autoMount: false
        )
        let secrets = SFTPSecrets(password: "hunter2", privateKeyPath: nil, keyPassphrase: nil)
        let cfg = try RcloneConfigBuilder.build(remote: r, sftpSecrets: secrets)
        XCTAssertTrue(cfg.contains("[\(RcloneConfigBuilder.sectionName)]"))
        XCTAssertTrue(cfg.contains("type = sftp"))
        XCTAssertTrue(cfg.contains("host = example.com"))
        XCTAssertTrue(cfg.contains("port = 22"))
        XCTAssertTrue(cfg.contains("user = alice"))
        XCTAssertFalse(cfg.contains("hunter2"))
    }

    func testSFTPKeyFileAuth() throws {
        let r = Remote(
            id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!,
            name: "h",
            backend: .sftp(SFTPConfig(host: "h", port: 2222, user: "u", remotePath: "/data", authKind: .keyFile)),
            mountProtocol: .webdav, autoMount: false
        )
        let secrets = SFTPSecrets(password: nil, privateKeyPath: "/tmp/id_ed25519", keyPassphrase: nil)
        let cfg = try RcloneConfigBuilder.build(remote: r, sftpSecrets: secrets)
        XCTAssertTrue(cfg.contains("key_file = /tmp/id_ed25519"))
        XCTAssertTrue(cfg.contains("port = 2222"))
    }

    func testKeyFileAuthRequiresPath() throws {
        let r = Remote(
            id: UUID(),
            name: "h",
            backend: .sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .keyFile)),
            mountProtocol: .webdav, autoMount: false
        )
        XCTAssertThrowsError(try RcloneConfigBuilder.build(
            remote: r,
            sftpSecrets: SFTPSecrets(password: nil, privateKeyPath: nil, keyPassphrase: nil)
        ))
    }

    func testKeyPassphraseIsNeverWrittenToConfig() throws {
        let r = Remote(
            id: UUID(),
            name: "h",
            backend: .sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .keyFile)),
            mountProtocol: .webdav, autoMount: false
        )
        let secrets = SFTPSecrets(password: nil, privateKeyPath: "/tmp/k", keyPassphrase: "s3cret-pass")
        let cfg = try RcloneConfigBuilder.build(remote: r, sftpSecrets: secrets)
        XCTAssertFalse(cfg.contains("s3cret-pass"))
    }

    func testKeyPassphraseEnvVarName() {
        // rclone reads RCLONE_CONFIG_<SECTION>_KEY_FILE_PASS and expects the obscured form.
        XCTAssertEqual(RcloneConfigBuilder.keyPassphraseEnvVar, "RCLONE_CONFIG_R_KEY_FILE_PASS")
    }

    func testObscuredPassphraseDiffersFromPlaintextAndRevealsBack() throws {
        let rclone = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/macsh/Resources/rclone")
        try XCTSkipUnless(FileManager.default.isExecutableFile(atPath: rclone.path),
                          "bundled rclone not fetched (run scripts/fetch-rclone.sh)")
        let obscured = try RcloneProcess.obscure(plaintext: "s3cret-pass", binary: rclone)
        XCTAssertFalse(obscured.isEmpty)
        XCTAssertNotEqual(obscured, "s3cret-pass")
        let p = Process()
        p.executableURL = rclone
        p.arguments = ["reveal", obscured]
        let out = Pipe(); p.standardOutput = out
        try p.run(); p.waitUntilExit()
        let revealed = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(revealed, "s3cret-pass")
    }
}
