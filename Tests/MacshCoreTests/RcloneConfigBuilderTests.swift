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
}
