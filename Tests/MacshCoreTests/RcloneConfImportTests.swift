import XCTest
@testable import MacshCore

final class RcloneConfParserTests: XCTestCase {
    func testParsesSectionsOptionsAndSplitsTypeOut() {
        let text = """
        # comment
        [my sftp]
        type = sftp
        host = example.com
        pass = OBS-secret

        ; another comment
        [drive]
        type = drive
        token = {"access_token":"a=b","expiry":"2030-01-01T00:00:00Z"}
        scope=drive
        """
        let s = RcloneConfParser.parse(text)
        XCTAssertEqual(s.map(\.name), ["my sftp", "drive"])
        XCTAssertEqual(s[0].type, "sftp")
        XCTAssertEqual(s[0].options, ["host": "example.com", "pass": "OBS-secret"])
        XCTAssertEqual(s[1].options["token"], #"{"access_token":"a=b","expiry":"2030-01-01T00:00:00Z"}"#)
        XCTAssertEqual(s[1].options["scope"], "drive")
    }

    func testIgnoresKeysOutsideSectionsAndHandlesMissingType() {
        let s = RcloneConfParser.parse("stray = 1\n[x]\nhost = h\n")
        XCTAssertEqual(s, [RcloneConfSection(name: "x", type: "", options: ["host": "h"])])
        XCTAssertTrue(RcloneConfParser.parse("").isEmpty)
    }

    func testDetectsEncryptedConfig() {
        XCTAssertTrue(RcloneConfParser.isEncrypted("RCLONE_ENCRYPT_V0:\nabc"))
        XCTAssertFalse(RcloneConfParser.isEncrypted("[x]\ntype = ftp\n"))
    }

    func testCandidatePathsFollowRcloneOrder() {
        XCTAssertEqual(
            RcloneConfParser.candidatePaths(env: ["RCLONE_CONFIG": "/etc/r.conf", "XDG_CONFIG_HOME": "/xdg"], home: "/Users/u"),
            ["/etc/r.conf", "/xdg/rclone/rclone.conf", "/Users/u/.rclone.conf"])
        XCTAssertEqual(
            RcloneConfParser.candidatePaths(env: [:], home: "/Users/u"),
            ["/Users/u/.config/rclone/rclone.conf", "/Users/u/.rclone.conf"])
    }

    func testLocateReturnsFirstExistingPath() {
        let found = RcloneConfParser.locate(env: [:], home: "/h", fileExists: { $0 == "/h/.rclone.conf" })
        XCTAssertEqual(found, "/h/.rclone.conf")
        XCTAssertNil(RcloneConfParser.locate(env: [:], home: "/h", fileExists: { _ in false }))
    }
}

final class RcloneConfImporterTests: XCTestCase {
    private let reveal: (String) throws -> String = { s in
        guard s.hasPrefix("OBS-") else { throw RcloneProcess.RevealError.failed("bad") }
        return String(s.dropFirst(4))
    }

    private func convert(_ type: String, _ options: [String: String], proto: MountProtocol = .nfs) -> ImportOutcome {
        RcloneConfImporter.convert(RcloneConfSection(name: "r1", type: type, options: options),
                                   defaultProtocol: proto, reveal: reveal, home: "/Users/u")
    }

    private func ready(_ o: ImportOutcome, file: StaticString = #filePath, line: UInt = #line) -> ImportedRemote? {
        if case .ready(let r) = o { return r }
        XCTFail("expected ready, got \(o)", file: file, line: line)
        return nil
    }

    private func reason(_ o: ImportOutcome) -> String? {
        if case .unsupported(let r) = o { return r }
        return nil
    }

    func testSFTPPassword() throws {
        let r = try XCTUnwrap(ready(convert("sftp", ["host": "h", "user": "u", "pass": "OBS-pw", "port": "2222"])))
        XCTAssertEqual(r.remote.name, "r1")
        XCTAssertEqual(r.remote.mountProtocol, .nfs)
        XCTAssertFalse(r.remote.autoMount)
        XCTAssertEqual(r.remote.backend, .sftp(SFTPConfig(host: "h", port: 2222, user: "u", remotePath: "", authKind: .password)))
        XCTAssertEqual(r.sftp?.password, "pw")
        XCTAssertTrue(r.ignoredOptions.isEmpty)
    }

    func testSFTPKeyFileExpandsHomeAndRevealsPassphrase() throws {
        let r = try XCTUnwrap(ready(convert("sftp", ["host": "h", "user": "u", "key_file": "~/.ssh/id", "key_file_pass": "OBS-pp",
                                                     "pass": "OBS-ignored", "use_insecure_cipher": "true"])))
        guard case .sftp(let cfg) = r.remote.backend else { return XCTFail() }
        XCTAssertEqual(cfg.authKind, .keyFile)
        XCTAssertEqual(cfg.port, 22)
        XCTAssertEqual(r.sftp?.privateKeyPath, "/Users/u/.ssh/id")
        XCTAssertEqual(r.sftp?.keyPassphrase, "pp")
        XCTAssertNil(r.sftp?.password)
        XCTAssertEqual(r.ignoredOptions, ["use_insecure_cipher"])
    }

    func testSFTPUnsupportedCases() {
        XCTAssertEqual(reason(convert("sftp", ["host": "h", "user": "u"])), "No password or key file (probably uses ssh-agent)")
        XCTAssertEqual(reason(convert("sftp", ["user": "u", "pass": "OBS-x"])), "The SFTP host is missing")
        XCTAssertEqual(reason(convert("sftp", ["host": "h", "pass": "OBS-x"])), "The SFTP user is missing")
    }

    func testS3MapsProviderAndNeedsBucket() throws {
        var r = try XCTUnwrap(ready(convert("s3", ["provider": "Cloudflare", "access_key_id": "AK", "secret_access_key": "SK",
                                                    "endpoint": "https://x.r2.cloudflarestorage.com", "region": "auto"])))
        XCTAssertTrue(r.needsBucket)
        XCTAssertEqual(r.s3?.accessKeyID, "AK")
        XCTAssertEqual(r.s3?.secretAccessKey, "SK")
        guard case .s3(let cfg) = r.remote.backend else { return XCTFail() }
        XCTAssertEqual(cfg.provider, .cloudflareR2)
        XCTAssertEqual(cfg.endpoint, "https://x.r2.cloudflarestorage.com")
        r.setBucket("  photos ")
        XCTAssertFalse(r.needsBucket)
        guard case .s3(let after) = r.remote.backend else { return XCTFail() }
        XCTAssertEqual(after.bucket, "photos")
    }

    func testS3ProviderMappingAndFallback() throws {
        for (name, expected) in [("AWS", S3Provider.aws), ("Wasabi", .wasabi), ("Minio", .minio),
                                 ("DigitalOcean", .digitalOcean), ("Ceph", .other), ("", .other)] {
            let r = try XCTUnwrap(ready(convert("s3", ["provider": name, "access_key_id": "a", "secret_access_key": "b"])))
            guard case .s3(let cfg) = r.remote.backend else { return XCTFail() }
            XCTAssertEqual(cfg.provider, expected, name)
            XCTAssertNil(cfg.endpoint)
        }
    }

    func testS3WithoutKeysIsUnsupported() {
        XCTAssertNotNil(reason(convert("s3", ["provider": "AWS", "env_auth": "true"])))
    }

    func testFTPTLSModesPortsAndDefaults() throws {
        func cfg(_ opts: [String: String]) throws -> FTPConfig {
            let r = try XCTUnwrap(ready(convert("ftp", opts.merging(["host": "h", "pass": "OBS-p"]) { a, _ in a })))
            guard case .ftp(let c) = r.remote.backend else { throw XCTSkip("not ftp") }
            return c
        }
        XCTAssertEqual(try cfg([:]).tlsMode, .off)
        XCTAssertEqual(try cfg([:]).port, 21)
        XCTAssertEqual(try cfg([:]).user, "anonymous")
        XCTAssertEqual(try cfg(["tls": "true"]).tlsMode, .implicit)
        XCTAssertEqual(try cfg(["tls": "true"]).port, 990)
        XCTAssertEqual(try cfg(["explicit_tls": "true", "user": "bob"]).tlsMode, .explicit)
        XCTAssertEqual(try cfg(["explicit_tls": "true", "user": "bob"]).user, "bob")
        XCTAssertEqual(try cfg(["port": "2121"]).port, 2121)
        XCTAssertEqual(reason(convert("ftp", ["host": "h"])), "No password saved for this FTP remote")
    }

    func testWebDAVBecomesGenericBackend() throws {
        let r = try XCTUnwrap(ready(convert("webdav", ["url": "https://c/dav", "vendor": "nextcloud", "user": "u", "pass": "OBS-app"])))
        guard case .rclone(let cfg) = r.remote.backend else { return XCTFail() }
        XCTAssertEqual(cfg.type, "webdav")
        XCTAssertEqual(cfg.options, ["url": "https://c/dav", "vendor": "nextcloud", "user": "u"])
        XCTAssertEqual(r.options, ["pass": "app"])

        let other = try XCTUnwrap(ready(convert("webdav", ["url": "https://c", "vendor": "sharepoint", "user": "u", "pass": "OBS-x"])))
        guard case .rclone(let c2) = other.remote.backend else { return XCTFail() }
        XCTAssertEqual(c2.options["vendor"], "other")
        XCTAssertNotNil(reason(convert("webdav", ["url": "https://c", "user": "u"])))
        XCTAssertNotNil(reason(convert("webdav", ["user": "u", "pass": "OBS-x"])))
    }

    func testDriveKeepsTokenAndOptionalFields() throws {
        let tok = #"{"access_token":"A","refresh_token":"R"}"#
        let r = try XCTUnwrap(ready(convert("drive", ["token": tok, "scope": "drive.readonly", "team_drive": "TD",
                                                       "client_id": "cid", "client_secret": "cs", "root_folder_id": "RF"])))
        guard case .rclone(let cfg) = r.remote.backend else { return XCTFail() }
        XCTAssertEqual(cfg.type, "drive")
        XCTAssertEqual(cfg.options, ["scope": "drive.readonly", "team_drive": "TD", "client_id": "cid", "root_folder_id": "RF"])
        XCTAssertEqual(r.options, ["token": tok, "client_secret": "cs"])
        XCTAssertNil(cfg.options["token"])

        let odd = try XCTUnwrap(ready(convert("drive", ["token": tok, "scope": "drive,drive.metadata.readonly"])))
        guard case .rclone(let c2) = odd.remote.backend else { return XCTFail() }
        XCTAssertEqual(c2.options["scope"], "drive")
        XCTAssertNotNil(reason(convert("drive", ["service_account_file": "/x.json"])))
    }

    func testUnsupportedTypeAndRevealFailure() {
        XCTAssertEqual(reason(convert("crypt", ["remote": "x:"])), "Type \"crypt\" is not supported by macsh yet")
        XCTAssertEqual(reason(convert("", [:])), "Type \"(none)\" is not supported by macsh yet")
        let failed = reason(convert("ftp", ["host": "h", "pass": "not-obscured"]))
        XCTAssertTrue(failed?.hasPrefix("Could not read a saved password") == true, failed ?? "")
    }

    func testUniqueName() {
        XCTAssertEqual(RcloneConfImporter.uniqueName("a", existing: []), "a")
        XCTAssertEqual(RcloneConfImporter.uniqueName("a", existing: ["A"]), "a (imported)")
        XCTAssertEqual(RcloneConfImporter.uniqueName("a", existing: ["a", "a (imported)"]), "a (imported 2)")
    }
}

@MainActor
final class RcloneConfImportManagerTests: XCTestCase {
    private func makeManager() throws -> (SessionManager, KeychainService, FakeRclone, URL) {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        let rclone = try FakeRclone.make(in: dir)
        let keychain = KeychainService(serviceName: "macsh.tests.\(UUID().uuidString)")
        let manager = SessionManager(store: RemoteStore(directory: dir), keychain: keychain, mounter: Mounter(),
                                     logsDir: dir.appendingPathComponent("logs"), rcloneBinary: rclone.binary)
        addTeardownBlock { @MainActor in
            for s in manager.sessions { try? manager.delete(s.id) }
            try? FileManager.default.removeItem(at: dir)
        }
        return (manager, keychain, rclone, dir)
    }

    private let conf = """
    [work-sftp]
    type = sftp
    host = h
    user = u
    pass = OBS-sftppw

    [photos]
    type = s3
    provider = AWS
    access_key_id = AK
    secret_access_key = SK

    [vault]
    type = crypt
    remote = work-sftp:

    [cloud]
    type = webdav
    url = https://c/dav
    vendor = nextcloud
    user = bob
    pass = OBS-apppw
    """

    func testImportsSupportedSectionsAndReportsTheRest() async throws {
        let (m, kc, _, _) = try makeManager()
        let sections = RcloneConfParser.parse(conf)
        let summary = await m.importRemotes(sections, defaultProtocol: .nfs, buckets: ["photos": "my-bucket"])

        XCTAssertEqual(summary.imported, ["work-sftp", "photos", "cloud"])
        XCTAssertEqual(summary.skipped.map(\.name), ["vault"])
        XCTAssertEqual(m.sessions.map(\.remote.name), ["work-sftp", "photos", "cloud"])
        XCTAssertTrue(m.sessions.allSatisfy { $0.remote.mountProtocol == .nfs && !$0.remote.autoMount })

        // Secrets are plaintext in the Keychain (re-obscured at mount), never in remotes.json.
        let sftp = m.sessions[0].remote
        XCTAssertEqual(try kc.get(remoteID: sftp.id, kind: .password), "sftppw")
        let s3 = m.sessions[1].remote
        XCTAssertEqual(try kc.get(remoteID: s3.id, kind: .s3AccessKeyID), "AK")
        XCTAssertEqual(try kc.get(remoteID: s3.id, kind: .s3SecretAccessKey), "SK")
        guard case .s3(let cfg) = s3.backend else { return XCTFail() }
        XCTAssertEqual(cfg.bucket, "my-bucket")
        let dav = m.sessions[2].remote
        XCTAssertEqual(try kc.get(remoteID: dav.id, kind: .option("pass")), "apppw")
    }

    func testS3WithoutBucketIsSkippedAndNamesAreMadeUnique() async throws {
        let (m, _, _, _) = try makeManager()
        try m.add(makeRemote(name: "cloud", backend: ftpBackend()), ftpSecrets: FTPSecrets(password: "x"))
        let summary = await m.importRemotes(RcloneConfParser.parse(conf), defaultProtocol: .webdav)
        XCTAssertEqual(summary.skipped.map(\.name), ["photos", "vault"])
        XCTAssertEqual(summary.skipped.first?.reason, "A bucket name is required")
        XCTAssertEqual(summary.imported, ["work-sftp", "cloud (imported)"])
    }

    func testImportedRemoteTestsConnectionWithItsSecret() async throws {
        let (m, _, rclone, _) = try makeManager()
        let ftpConf = "[box]\ntype = ftp\nhost = h\nuser = u\npass = OBS-ftppw\n"
        let summary = await m.importRemotes(RcloneConfParser.parse(ftpConf), defaultProtocol: .webdav)
        XCTAssertEqual(summary.imported, ["box"])
        let result = await m.testConnection(m.sessions[0].remote)
        XCTAssertTrue(result.ok, result.message)
        XCTAssertTrue(rclone.recordedLines().contains("ENV:RCLONE_CONFIG_R_PASS=OBS-ftppw"))
    }

    func testRevealRunsRclone() throws {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let rclone = try FakeRclone.make(in: dir)
        XCTAssertEqual(try RcloneProcess.reveal(obscured: "OBS-hello", binary: rclone.binary), "hello")
        XCTAssertThrowsError(try RcloneProcess.reveal(obscured: "garbage", binary: rclone.binary)) {
            XCTAssertTrue(($0 as? LocalizedError)?.errorDescription?.contains("too short") == true)
        }
    }
}

final class RcloneConfImporterSMBTests: XCTestCase {
    private let reveal: (String) throws -> String = { String($0.dropFirst(4)) }

    private func convert(_ options: [String: String]) -> ImportOutcome {
        RcloneConfImporter.convert(RcloneConfSection(name: "nas", type: "smb", options: options),
                                   defaultProtocol: .webdav, reveal: reveal, home: "/h")
    }

    func testSMBSectionNeedsAShare() throws {
        guard case .ready(var r) = convert(["host": "nas", "user": "bob", "pass": "OBS-pw", "domain": "HOME", "spn": "x"]) else {
            return XCTFail("expected ready")
        }
        XCTAssertTrue(r.needsRemotePath)
        XCTAssertEqual(r.options, ["pass": "pw"])
        XCTAssertEqual(r.ignoredOptions, ["spn"])
        guard case .rclone(let cfg) = r.remote.backend else { return XCTFail() }
        XCTAssertEqual(cfg.type, "smb")
        XCTAssertEqual(cfg.options, ["host": "nas", "port": "445", "user": "bob", "domain": "HOME"])
        r.setSharePath(" media/photos ")
        XCTAssertFalse(r.needsRemotePath)
        guard case .rclone(let after) = r.remote.backend else { return XCTFail() }
        XCTAssertEqual(after.remotePath, "media/photos")
        r.setSharePath("")
        XCTAssertTrue(r.needsRemotePath)
    }

    func testSMBInvalidPortFallsBackAndMissingPartsAreUnsupported() {
        guard case .ready(let r) = convert(["host": "nas", "user": "u", "pass": "OBS-x", "port": "abc"]),
              case .rclone(let cfg) = r.remote.backend else { return XCTFail() }
        XCTAssertEqual(cfg.options["port"], "445")
        if case .unsupported(let m) = convert(["user": "u", "pass": "OBS-x"]) { XCTAssertEqual(m, "The SMB host is missing") }
        else { XCTFail() }
        if case .unsupported = convert(["host": "nas"]) {} else { XCTFail() }
    }
}

@MainActor
final class RcloneConfImportSMBManagerTests: XCTestCase {
    func testImportRequiresAndAppliesTheShare() async throws {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        let rclone = try FakeRclone.make(in: dir)
        let kc = KeychainService(serviceName: "macsh.tests.\(UUID().uuidString)")
        let m = SessionManager(store: RemoteStore(directory: dir), keychain: kc,
                               mounter: Mounter(), logsDir: dir.appendingPathComponent("logs"), rcloneBinary: rclone.binary)
        addTeardownBlock { @MainActor in
            for s in m.sessions { try? m.delete(s.id) }
            try? FileManager.default.removeItem(at: dir)
        }
        let sections = RcloneConfParser.parse("[nas]\ntype = smb\nhost = nas\nuser = bob\npass = OBS-pw\n")

        let skipped = await m.importRemotes(sections, defaultProtocol: .nfs)
        XCTAssertEqual(skipped.skipped.first?.reason, "A share name is required")
        XCTAssertTrue(m.sessions.isEmpty)

        let ok = await m.importRemotes(sections, defaultProtocol: .nfs, sharePaths: ["nas": "media"])
        XCTAssertEqual(ok.imported, ["nas"])
        guard case .rclone(let cfg) = m.sessions[0].remote.backend else { return XCTFail() }
        XCTAssertEqual(cfg.remotePath, "media")
        XCTAssertEqual(try kc.get(remoteID: m.sessions[0].id, kind: .option("pass")), "pw")
    }
}
