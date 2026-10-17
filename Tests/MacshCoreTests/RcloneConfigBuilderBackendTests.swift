import XCTest
@testable import MacshCore

final class RcloneConfigBuilderBackendTests: XCTestCase {
    private func remote(_ backend: Backend) -> Remote {
        Remote(id: UUID(), name: "r", backend: backend, mountProtocol: .webdav, autoMount: false)
    }

    private let sftp = Backend.sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .password))

    func testSFTPKnownHostsFileEmitted() throws {
        let cfg = try RcloneConfigBuilder.build(
            remote: remote(sftp),
            secrets: BackendSecrets(sftp: SFTPSecrets(password: "pw", privateKeyPath: nil, keyPassphrase: nil)),
            knownHostsPath: "/tmp/known_hosts"
        )
        XCTAssertTrue(cfg.contains("known_hosts_file = /tmp/known_hosts"))
    }

    func testSFTPGeneratedKeyUsesKeyFile() throws {
        let r = remote(.sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .generatedKey)))
        let cfg = try RcloneConfigBuilder.build(
            remote: r,
            secrets: BackendSecrets(sftp: SFTPSecrets(password: nil, privateKeyPath: "/tmp/k", keyPassphrase: nil))
        )
        XCTAssertTrue(cfg.contains("key_file = /tmp/k"))
    }

    func testSFTPMissingSecretsThrows() {
        XCTAssertThrowsError(try RcloneConfigBuilder.build(remote: remote(sftp), secrets: BackendSecrets())) {
            XCTAssertEqual($0 as? RcloneConfigError, .passwordAuthRequiresPassword)
        }
    }

    func testSFTPPasswordAuthWithoutPasswordThrows() {
        let secrets = BackendSecrets(sftp: SFTPSecrets(password: nil, privateKeyPath: nil, keyPassphrase: nil))
        XCTAssertThrowsError(try RcloneConfigBuilder.build(remote: remote(sftp), secrets: secrets)) {
            XCTAssertEqual($0 as? RcloneConfigError, .passwordAuthRequiresPassword)
        }
    }

    func testKeyFileAuthWithoutPathThrowsExpectedError() {
        let r = remote(.sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .keyFile)))
        let secrets = BackendSecrets(sftp: SFTPSecrets(password: nil, privateKeyPath: nil, keyPassphrase: nil))
        XCTAssertThrowsError(try RcloneConfigBuilder.build(remote: r, secrets: secrets)) {
            XCTAssertEqual($0 as? RcloneConfigError, .keyFileAuthRequiresPath)
        }
    }

    func testS3Config() throws {
        let r = remote(.s3(S3Config(provider: .wasabi, region: "us-east-1",
                                    endpoint: "https://s3.wasabisys.com", bucket: "b", prefix: "")))
        let cfg = try RcloneConfigBuilder.build(
            remote: r,
            secrets: BackendSecrets(s3: S3Secrets(accessKeyID: "AKID", secretAccessKey: "SECRET"))
        )
        XCTAssertTrue(cfg.contains("type = s3"))
        XCTAssertTrue(cfg.contains("provider = Wasabi"))
        XCTAssertTrue(cfg.contains("access_key_id = AKID"))
        XCTAssertTrue(cfg.contains("region = us-east-1"))
        XCTAssertTrue(cfg.contains("endpoint = https://s3.wasabisys.com"))
        XCTAssertFalse(cfg.contains("SECRET"), "secret must never be written to the config file")
    }

    func testS3OmitsEmptyRegionAndEndpoint() throws {
        let r = remote(.s3(S3Config(provider: .aws, region: "", endpoint: "", bucket: "b", prefix: "")))
        let cfg = try RcloneConfigBuilder.build(
            remote: r,
            secrets: BackendSecrets(s3: S3Secrets(accessKeyID: "AKID", secretAccessKey: "S"))
        )
        XCTAssertFalse(cfg.contains("region ="))
        XCTAssertFalse(cfg.contains("endpoint ="))
    }

    func testS3MissingCredentialsThrows() {
        let r = remote(.s3(S3Config(provider: .aws, region: "r", endpoint: nil, bucket: "b", prefix: "")))
        XCTAssertThrowsError(try RcloneConfigBuilder.build(remote: r, secrets: BackendSecrets())) {
            XCTAssertEqual($0 as? RcloneConfigError, .missingS3Credentials)
        }
    }

    func testFTPTLSModes() throws {
        let secrets = BackendSecrets(ftp: FTPSecrets(password: "pw"))
        func build(_ mode: FTPTLSMode) throws -> String {
            try RcloneConfigBuilder.build(
                remote: remote(.ftp(FTPConfig(host: "f", port: 21, user: "u", remotePath: "/", tlsMode: mode))),
                secrets: secrets
            )
        }
        let off = try build(.off)
        XCTAssertTrue(off.contains("type = ftp"))
        XCTAssertFalse(off.contains("tls ="))

        let explicit = try build(.explicit)
        XCTAssertTrue(explicit.contains("tls = true"))
        XCTAssertFalse(explicit.contains("explicit_tls"))

        let implicit = try build(.implicit)
        XCTAssertTrue(implicit.contains("tls = true"))
        XCTAssertTrue(implicit.contains("explicit_tls = false"))
        XCTAssertFalse(implicit.contains("pw"))
    }

    func testFTPMissingPasswordThrows() {
        let r = remote(.ftp(FTPConfig(host: "f", port: 21, user: "u", remotePath: "/", tlsMode: .off)))
        XCTAssertThrowsError(try RcloneConfigBuilder.build(remote: r, secrets: BackendSecrets())) {
            XCTAssertEqual($0 as? RcloneConfigError, .missingFTPPassword)
        }
    }

    func testEnvVarNames() {
        XCTAssertEqual(RcloneConfigBuilder.passwordEnvVar(remoteID: UUID()), "RCLONE_CONFIG_R_PASS")
        XCTAssertEqual(RcloneConfigBuilder.s3SecretEnvVar(remoteID: UUID()), "RCLONE_CONFIG_R_SECRET_ACCESS_KEY")
    }
}

final class RcloneConfigBuilderGenericTests: XCTestCase {
    private func webdav() -> Remote { makeRemote(backend: webdavBackend()) }

    func testWebDAVConfigListsSortedOptionsAndNoSecret() throws {
        let cfg = try RcloneConfigBuilder.build(
            remote: webdav(), secrets: BackendSecrets(options: ["pass": "TOPSECRET"]))
        XCTAssertEqual(cfg, """
        [r]
        type = webdav
        url = https://cloud.example.com/remote.php/dav/files/bob/
        user = bob
        vendor = nextcloud

        """)
        XCTAssertFalse(cfg.contains("TOPSECRET"))
        XCTAssertFalse(cfg.contains("pass"))
    }

    func testMissingOrEmptySecretThrows() {
        for secrets in [BackendSecrets(), BackendSecrets(options: ["pass": ""])] {
            XCTAssertThrowsError(try RcloneConfigBuilder.build(remote: webdav(), secrets: secrets)) {
                XCTAssertEqual($0 as? RcloneConfigError, .missingSecret("pass"))
            }
        }
    }

    func testBackendWithoutSecretsNeedsNone() throws {
        let r = makeRemote(backend: .rclone(RcloneBackendConfig(
            type: "alias", options: ["remote": "/tmp"], secretOptions: [], remotePath: "")))
        let cfg = try RcloneConfigBuilder.build(remote: r, secrets: BackendSecrets())
        XCTAssertTrue(cfg.contains("type = alias"))
        XCTAssertTrue(cfg.contains("remote = /tmp"))
    }

    func testOptionEnvVarUppercasesName() {
        XCTAssertEqual(RcloneConfigBuilder.optionEnvVar("pass"), "RCLONE_CONFIG_R_PASS")
        XCTAssertEqual(RcloneConfigBuilder.optionEnvVar("client_secret"), "RCLONE_CONFIG_R_CLIENT_SECRET")
    }
}
