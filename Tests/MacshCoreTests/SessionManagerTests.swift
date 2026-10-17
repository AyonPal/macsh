import XCTest
import Combine
@testable import MacshCore

private final class FakeMounter: Mounter {
    private let lock = NSLock()
    private var _failMount = false
    private var _webdavMounts: [(port: Int, baseurl: String)] = []
    private var _nfsMounts: [(port: Int, mountpoint: String)] = []
    private var _unmounted: [String] = []
    private var _reconciled: [String] = []

    var failMount: Bool {
        get { lock.withLock { _failMount } }
        set { lock.withLock { _failMount = newValue } }
    }
    var webdavMounts: [(port: Int, baseurl: String)] { lock.withLock { _webdavMounts } }
    var nfsMounts: [(port: Int, mountpoint: String)] { lock.withLock { _nfsMounts } }
    var unmounted: [String] { lock.withLock { _unmounted } }
    var reconciled: [String] { lock.withLock { _reconciled } }

    override func mountWebDAV(host: String, port: Int, baseurl: String, user: String, password: String) throws -> String {
        if failMount { throw Mounter.MountError.netFSFailed(status: 1) }
        lock.withLock { _webdavMounts.append((port, baseurl)) }
        return "/Volumes/fake\(baseurl)"
    }

    override func mountNFS(host: String, port: Int, exportPath: String, name: String, mountpoint: String) throws {
        if failMount { throw Mounter.MountError.mountFailed(stderr: "x", exitCode: 1) }
        lock.withLock { _nfsMounts.append((port, mountpoint)) }
    }

    override func resolveMountpoint(name: String) throws -> String { "/Volumes/\(name)" }

    override func unmount(mountpoint: String) throws { lock.withLock { _unmounted.append(mountpoint) } }

    @discardableResult
    override func reconcileStaleMount(volumeName: String) -> Bool {
        lock.withLock { _reconciled.append(volumeName) }
        return false
    }
}

@MainActor
final class SessionManagerTests: XCTestCase {
    private struct Fixture {
        let manager: SessionManager
        let mounter: FakeMounter
        let keychain: KeychainService
        let store: RemoteStore
        let rclone: FakeRclone
        let dir: URL
    }

    private func makeFixture() throws -> Fixture {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        let rclone = try FakeRclone.make(in: dir)
        let keychain = KeychainService(serviceName: "macsh.tests.\(UUID().uuidString)")
        let store = RemoteStore(directory: dir)
        let mounter = FakeMounter()
        let manager = SessionManager(
            store: store, keychain: keychain, mounter: mounter,
            logsDir: dir.appendingPathComponent("logs"), rcloneBinary: rclone.binary
        )
        addTeardownBlock { @MainActor in
            manager.shutdownAll()
            for s in manager.sessions { try? manager.delete(s.id) }
            try? FileManager.default.removeItem(at: dir)
        }
        return Fixture(manager: manager, mounter: mounter, keychain: keychain, store: store, rclone: rclone, dir: dir)
    }

    /// Runs an async throwing block and returns the error it threw, if any.
    private func thrownError(_ block: () async throws -> Void) async -> Error? {
        do { try await block(); return nil } catch { return error }
    }

    private let pw = SFTPSecrets(password: "pw", privateKeyPath: nil, keyPassphrase: nil)

    // MARK: - CRUD

    func testReloadWithEmptyStore() throws {
        let f = try makeFixture()
        try f.manager.reload()
        XCTAssertTrue(f.manager.sessions.isEmpty)
    }

    func testAddPersistsRemoteAndSecrets() throws {
        let f = try makeFixture()
        let r = makeRemote(backend: sftpBackend())
        try f.manager.add(r, sftpSecrets: SFTPSecrets(password: "pw", privateKeyPath: "/k", keyPassphrase: "pp"))

        XCTAssertEqual(f.manager.sessions.map(\.id), [r.id])
        XCTAssertEqual(try f.store.load(), [r])
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .password), "pw")
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .keyPassphrase), "pp")
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .privateKey), "/k")
    }

    func testAddStoresS3AndFTPSecrets() throws {
        let f = try makeFixture()
        let s3 = makeRemote(backend: s3Backend())
        let ftp = makeRemote(backend: ftpBackend())
        try f.manager.add(s3, s3Secrets: S3Secrets(accessKeyID: "AK", secretAccessKey: "SK"))
        try f.manager.add(ftp, ftpSecrets: FTPSecrets(password: "ftppw"))

        XCTAssertEqual(try f.keychain.get(remoteID: s3.id, kind: .s3AccessKeyID), "AK")
        XCTAssertEqual(try f.keychain.get(remoteID: s3.id, kind: .s3SecretAccessKey), "SK")
        XCTAssertEqual(try f.keychain.get(remoteID: ftp.id, kind: .password), "ftppw")
        XCTAssertEqual(f.manager.sessions.count, 2)
    }

    func testReloadKeepsExistingSessionInstances() throws {
        let f = try makeFixture()
        try f.manager.add(makeRemote(backend: sftpBackend()), sftpSecrets: pw)
        let before = f.manager.sessions[0]
        try f.manager.reload()
        XCTAssertTrue(f.manager.sessions[0] === before)
    }

    func testStatusChangeRepublishesSessions() throws {
        let f = try makeFixture()
        try f.manager.add(makeRemote(backend: sftpBackend()), sftpSecrets: pw)
        var emissions = 0
        let cancel = f.manager.$sessions.sink { _ in emissions += 1 }
        defer { cancel.cancel() }
        let initial = emissions
        f.manager.sessions[0].transition(to: .starting)
        XCTAssertGreaterThan(emissions, initial)
    }

    func testUpdateBlankSecretKeepsExistingAndNonBlankOverwrites() throws {
        let f = try makeFixture()
        var r = makeRemote(backend: sftpBackend())
        try f.manager.add(r, sftpSecrets: SFTPSecrets(password: "old", privateKeyPath: nil, keyPassphrase: nil))

        r.name = "renamed"
        try f.manager.update(r, sftpSecrets: SFTPSecrets(password: "", privateKeyPath: "", keyPassphrase: ""))
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .password), "old")
        XCTAssertEqual(try f.store.load().first?.name, "renamed")
        XCTAssertEqual(f.manager.sessions.first?.remote.name, "renamed")

        try f.manager.update(r, sftpSecrets: SFTPSecrets(password: "new", privateKeyPath: "/p", keyPassphrase: "pp"))
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .password), "new")
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .privateKey), "/p")
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .keyPassphrase), "pp")
    }

    func testUpdateS3AndFTPSecrets() throws {
        let f = try makeFixture()
        let s3 = makeRemote(backend: s3Backend())
        let ftp = makeRemote(backend: ftpBackend())
        try f.manager.add(s3, s3Secrets: S3Secrets(accessKeyID: "AK", secretAccessKey: "SK"))
        try f.manager.add(ftp, ftpSecrets: FTPSecrets(password: "one"))

        try f.manager.update(s3, s3Secrets: S3Secrets(accessKeyID: "", secretAccessKey: "SK2"))
        XCTAssertEqual(try f.keychain.get(remoteID: s3.id, kind: .s3AccessKeyID), "AK")
        XCTAssertEqual(try f.keychain.get(remoteID: s3.id, kind: .s3SecretAccessKey), "SK2")

        try f.manager.update(ftp, ftpSecrets: FTPSecrets(password: ""))
        XCTAssertEqual(try f.keychain.get(remoteID: ftp.id, kind: .password), "one")
        try f.manager.update(ftp, ftpSecrets: FTPSecrets(password: "two"))
        XCTAssertEqual(try f.keychain.get(remoteID: ftp.id, kind: .password), "two")
    }

    func testUpdateUnknownRemoteThrows() throws {
        let f = try makeFixture()
        XCTAssertThrowsError(try f.manager.update(makeRemote(backend: sftpBackend())))
    }

    func testDeleteRemovesRemoteAndSecrets() throws {
        let f = try makeFixture()
        let r = makeRemote(backend: sftpBackend())
        try f.manager.add(r, sftpSecrets: pw)
        try f.manager.delete(r.id)
        XCTAssertTrue(f.manager.sessions.isEmpty)
        XCTAssertTrue(try f.store.load().isEmpty)
        XCTAssertNil(try f.keychain.get(remoteID: r.id, kind: .password))
    }

    func testBackoffDelaySchedule() {
        XCTAssertEqual(SessionManager.backoffDelay(attempt: 0), 0)
        XCTAssertEqual(SessionManager.backoffDelay(attempt: 1), 1)
        XCTAssertEqual(SessionManager.backoffDelay(attempt: 2), 5)
        XCTAssertEqual(SessionManager.backoffDelay(attempt: 3), 30)
        XCTAssertEqual(SessionManager.backoffDelay(attempt: 4), 300)
        XCTAssertEqual(SessionManager.backoffDelay(attempt: 99), 300)
    }

    func testLogURL() throws {
        let f = try makeFixture()
        let id = UUID()
        XCTAssertEqual(f.manager.logURL(for: id).lastPathComponent, "\(id.uuidString).log")
    }

    func testUnknownIDsAreNoOps() async throws {
        let f = try makeFixture()
        let m = await thrownError { try await f.manager.mount(remoteID: UUID()) }
        let u = await thrownError { try await f.manager.unmount(remoteID: UUID()) }
        XCTAssertNil(m)
        XCTAssertNil(u)
    }

    // MARK: - Mount flows

    func testMountSFTPPasswordWebDAVThenUnmount() async throws {
        let f = try makeFixture()
        let r = makeRemote(name: "my server", backend: sftpBackend())
        try f.manager.add(r, sftpSecrets: pw)

        try await f.manager.mount(remoteID: r.id)

        let session = try XCTUnwrap(f.manager.sessions.first)
        XCTAssertEqual(session.status, .mounted(at: "/Volumes/fake/my server"))
        XCTAssertEqual(f.mounter.webdavMounts.first?.baseurl, "/my server")
        let lines = f.rclone.recordedLines()
        XCTAssertEqual(Array(lines.prefix(3)), ["serve", "webdav", "r:/data"])
        XCTAssertTrue(lines.contains("ENV:RCLONE_CONFIG_R_PASS=OBS-pw"), "password must be passed obscured via env")
        let proc = try XCTUnwrap(session.rcloneProcess)

        try await f.manager.unmount(remoteID: r.id)
        XCTAssertEqual(session.status, .idle)
        XCTAssertNil(session.mountpoint)
        XCTAssertNil(session.rcloneProcess)
        XCTAssertEqual(f.mounter.unmounted, ["/Volumes/fake/my server"])
        proc.waitUntilExit()
        XCTAssertFalse(proc.isRunning)
    }

    func testMountS3PassesSecretViaEnvAndBuildsRemotePath() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: s3Backend(prefix: "dir"))
        try f.manager.add(r, s3Secrets: S3Secrets(accessKeyID: "AK", secretAccessKey: "SK"))

        try await f.manager.mount(remoteID: r.id)

        let lines = f.rclone.recordedLines()
        XCTAssertEqual(lines[2], "r:bkt/dir")
        XCTAssertTrue(lines.contains("ENV:RCLONE_CONFIG_R_SECRET_ACCESS_KEY=SK"))
        try await f.manager.unmount(remoteID: r.id)
    }

    func testMountS3WithoutPrefixUsesBucketOnly() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: s3Backend(prefix: ""))
        try f.manager.add(r, s3Secrets: S3Secrets(accessKeyID: "AK", secretAccessKey: "SK"))
        try await f.manager.mount(remoteID: r.id)
        XCTAssertEqual(f.rclone.recordedLines()[2], "r:bkt")
        try await f.manager.unmount(remoteID: r.id)
    }

    func testMountS3MissingCredentialsFails() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: s3Backend())
        try f.manager.add(r)

        let error = await thrownError { try await f.manager.mount(remoteID: r.id) }
        XCTAssertEqual(error as? RcloneConfigError, .missingS3Credentials)
        guard case .failed = f.manager.sessions[0].status else {
            return XCTFail("expected failed status, got \(f.manager.sessions[0].status)")
        }
    }

    func testMountFTPMissingPasswordFails() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: ftpBackend())
        try f.manager.add(r)
        let error = await thrownError { try await f.manager.mount(remoteID: r.id) }
        XCTAssertEqual(error as? RcloneConfigError, .missingFTPPassword)
    }

    func testMountFTPObscuresPassword() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: ftpBackend())
        try f.manager.add(r, ftpSecrets: FTPSecrets(password: "ftppw"))
        try await f.manager.mount(remoteID: r.id)
        XCTAssertTrue(f.rclone.recordedLines().contains("ENV:RCLONE_CONFIG_R_PASS=OBS-ftppw"))
        try await f.manager.unmount(remoteID: r.id)
    }

    // MARK: - Generic rclone backend (WebDAV)

    func testAddAndUpdateStoreGenericOptionSecrets() throws {
        let f = try makeFixture()
        let r = makeRemote(backend: webdavBackend())
        try f.manager.add(r, optionSecrets: ["pass": "apppw"])
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .option("pass")), "apppw")

        try f.manager.update(r, optionSecrets: ["pass": ""])
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .option("pass")), "apppw", "blank keeps existing")
        try f.manager.update(r, optionSecrets: ["pass": "newpw"])
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .option("pass")), "newpw")
    }

    func testDeleteRemovesGenericAndS3Secrets() throws {
        let f = try makeFixture()
        let w = makeRemote(backend: webdavBackend())
        let s3 = makeRemote(backend: s3Backend())
        try f.manager.add(w, optionSecrets: ["pass": "pw"])
        try f.manager.add(s3, s3Secrets: S3Secrets(accessKeyID: "AK", secretAccessKey: "SK"))
        try f.manager.delete(w.id)
        try f.manager.delete(s3.id)
        XCTAssertNil(try f.keychain.get(remoteID: w.id, kind: .option("pass")))
        XCTAssertNil(try f.keychain.get(remoteID: s3.id, kind: .s3AccessKeyID))
        XCTAssertNil(try f.keychain.get(remoteID: s3.id, kind: .s3SecretAccessKey))
    }

    func testMountWebDAVBackendObscuresPasswordAndServesRemotePath() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: webdavBackend(remotePath: "docs"))
        try f.manager.add(r, optionSecrets: ["pass": "apppw"])
        try await f.manager.mount(remoteID: r.id)

        let lines = f.rclone.recordedLines()
        XCTAssertTrue(lines.contains("ENV:RCLONE_CONFIG_R_PASS=OBS-apppw"))
        XCTAssertTrue(lines.contains("r:docs"))
        try await f.manager.unmount(remoteID: r.id)
    }

    func testMountWebDAVBackendMissingSecretFails() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: webdavBackend())
        try f.manager.add(r)
        let error = await thrownError { try await f.manager.mount(remoteID: r.id) }
        XCTAssertEqual(error as? RcloneConfigError, .missingSecret("pass"))
        if case .failed = f.manager.sessions[0].status {} else { XCTFail("expected failed status") }
    }

    // MARK: - OAuth backend (Google Drive)

    func testMountDriveSendsTokenUnobscuredAndSkipsOptionalSecret() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: driveBackend())
        try f.manager.add(r, optionSecrets: ["token": "TOKENJSON", "client_secret": ""])
        try await f.manager.mount(remoteID: r.id)
        let lines = f.rclone.recordedLines()
        XCTAssertTrue(lines.contains("ENV:RCLONE_CONFIG_R_TOKEN=TOKENJSON"), "token is not obscured")
        XCTAssertFalse(lines.contains { $0.hasPrefix("ENV:RCLONE_CONFIG_R_CLIENT_SECRET") })
        try await f.manager.unmount(remoteID: r.id)
    }

    func testRefreshedTokenIsWrittenBackToKeychainOnUnmount() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: driveBackend())
        try f.manager.add(r, optionSecrets: ["token": "OLD"])
        // Fake rclone appends this to its config while serving, like a real token refresh.
        try "NEWTOKEN".write(to: f.dir.appendingPathComponent("refresh-token.txt"), atomically: true, encoding: .utf8)

        try await f.manager.mount(remoteID: r.id)
        let configURL = try XCTUnwrap(f.manager.sessions[0].rcloneConfigURL)
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .option("token")), "OLD", "not persisted until unmount")
        try await f.manager.unmount(remoteID: r.id)

        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .option("token")), "NEWTOKEN")
        XCTAssertFalse(FileManager.default.fileExists(atPath: configURL.path), "temp config removed")
    }

    func testUnchangedTokenIsLeftAloneAndNonRefreshableOptionsAreIgnored() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: webdavBackend())
        try f.manager.add(r, optionSecrets: ["pass": "apppw"])
        try "NEWTOKEN".write(to: f.dir.appendingPathComponent("refresh-token.txt"), atomically: true, encoding: .utf8)
        try await f.manager.mount(remoteID: r.id)
        try await f.manager.unmount(remoteID: r.id)
        XCTAssertEqual(try f.keychain.get(remoteID: r.id, kind: .option("pass")), "apppw")
        XCTAssertNil(try f.keychain.get(remoteID: r.id, kind: .option("token")))
    }

    // MARK: - Mount options and Test connection

    func testMountPassesReadOnlyAndBandwidthLimit() async throws {
        let f = try makeFixture()
        var r = makeRemote(backend: ftpBackend())
        r.readOnly = true
        r.bandwidthLimit = "10M:1M"
        try f.manager.add(r, ftpSecrets: FTPSecrets(password: "pw"))
        try await f.manager.mount(remoteID: r.id)
        let lines = f.rclone.recordedLines()
        XCTAssertTrue(lines.contains("--read-only"))
        let i = try XCTUnwrap(lines.firstIndex(of: "--bwlimit"))
        XCTAssertEqual(lines[i + 1], "10M:1M")
        try await f.manager.unmount(remoteID: r.id)
    }

    func testMountWithoutOptionsHasNoReadOnlyOrBwlimit() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: ftpBackend(), proto: .nfs)
        try f.manager.add(r, ftpSecrets: FTPSecrets(password: "pw"))
        try await f.manager.mount(remoteID: r.id)
        let lines = f.rclone.recordedLines()
        XCTAssertFalse(lines.contains("--read-only"))
        XCTAssertFalse(lines.contains("--bwlimit"))
        try await f.manager.unmount(remoteID: r.id)
    }

    func testConnectionUsesUnsavedFormSecretsAndStoresNothing() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: ftpBackend())          // never added
        let result = await f.manager.testConnection(r, draft: .init(ftp: FTPSecrets(password: "typed")))
        XCTAssertEqual(result, .success("Connected — 2 items found"))
        let lines = f.rclone.recordedLines()
        XCTAssertEqual(lines.first, "lsf")
        XCTAssertTrue(lines.contains("ENV:RCLONE_CONFIG_R_PASS=OBS-typed"))
        XCTAssertTrue(f.manager.sessions.isEmpty)
        XCTAssertNil(try f.keychain.get(remoteID: r.id, kind: .password))
    }

    func testConnectionFallsBackToSavedSecretWhenFormIsBlank() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: ftpBackend())
        try f.manager.add(r, ftpSecrets: FTPSecrets(password: "saved"))
        let result = await f.manager.testConnection(r, draft: .init(ftp: FTPSecrets(password: "")))
        XCTAssertTrue(result.ok)
        XCTAssertTrue(f.rclone.recordedLines().contains("ENV:RCLONE_CONFIG_R_PASS=OBS-saved"))
    }

    func testConnectionWithoutAnySecretExplainsWhatIsMissing() async throws {
        let f = try makeFixture()
        let result = await f.manager.testConnection(makeRemote(backend: ftpBackend()))
        XCTAssertFalse(result.ok)
        XCTAssertEqual(result.message, "No password is saved for this remote.")
        let drive = await f.manager.testConnection(makeRemote(backend: driveBackend()))
        XCTAssertTrue(drive.message.contains("\"token\""), drive.message)
    }

    func testConnectionForS3UsesBucketAndPrefixAsPath() async throws {
        let f = try makeFixture()
        let result = await f.manager.testConnection(
            makeRemote(backend: s3Backend(prefix: "pre")),
            draft: .init(s3: S3Secrets(accessKeyID: "AK", secretAccessKey: "SK")))
        XCTAssertTrue(result.ok)
        let lines = f.rclone.recordedLines()
        XCTAssertEqual(Array(lines.prefix(2)), ["lsf", "r:bkt/pre"])
        XCTAssertTrue(lines.contains("ENV:RCLONE_CONFIG_R_SECRET_ACCESS_KEY=SK"))
    }

    func testConnectionWithGeneratedKeyCleansUpTheTemporaryKey() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: sftpBackend(auth: .generatedKey))
        let result = await f.manager.testConnection(
            r, draft: .init(sftp: SFTPSecrets(password: nil, privateKeyPath: "PEMDATA", keyPassphrase: nil)))
        XCTAssertTrue(result.ok)
        let keyPath = FileManager.default.temporaryDirectory.appendingPathComponent("macsh-key-\(r.id.uuidString)").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyPath))
    }

    func testMountNFSUsesResolvedMountpoint() async throws {
        let f = try makeFixture()
        let r = makeRemote(name: "nfsbox", backend: sftpBackend(), proto: .nfs)
        try f.manager.add(r, sftpSecrets: pw)

        try await f.manager.mount(remoteID: r.id)

        XCTAssertEqual(f.manager.sessions[0].status, .mounted(at: "/Volumes/nfsbox"))
        XCTAssertEqual(f.mounter.nfsMounts.first?.mountpoint, "/Volumes/nfsbox")
        XCTAssertEqual(f.rclone.recordedLines()[1], "nfs")
        try await f.manager.unmount(remoteID: r.id)
    }

    func testMountKeyFileAuthUsesStoredPath() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: sftpBackend(auth: .keyFile))
        try f.manager.add(r, sftpSecrets: SFTPSecrets(password: nil, privateKeyPath: "/keys/id", keyPassphrase: nil))
        try await f.manager.mount(remoteID: r.id)
        XCTAssertEqual(f.manager.sessions[0].status, .mounted(at: "/Volumes/fake/test-remote"))
        try await f.manager.unmount(remoteID: r.id)
    }

    func testGeneratedKeyIsWrittenWith0600AndRemovedOnUnmount() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: sftpBackend(auth: .generatedKey))
        try f.manager.add(r, sftpSecrets: SFTPSecrets(password: nil, privateKeyPath: "PEM-DATA", keyPassphrase: nil))

        try await f.manager.mount(remoteID: r.id)
        let keyURL = try XCTUnwrap(f.manager.sessions[0].ephemeralKeyURL)
        XCTAssertEqual(try String(contentsOf: keyURL, encoding: .utf8), "PEM-DATA")
        let perms = try FileManager.default.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)

        try await f.manager.unmount(remoteID: r.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyURL.path))
    }

    func testMountFailureMarksFailedAndCleansEphemeralKey() async throws {
        let f = try makeFixture()
        f.mounter.failMount = true
        let r = makeRemote(backend: sftpBackend(auth: .generatedKey))
        try f.manager.add(r, sftpSecrets: SFTPSecrets(password: nil, privateKeyPath: "PEM", keyPassphrase: nil))

        let error = await thrownError { try await f.manager.mount(remoteID: r.id) }
        XCTAssertNotNil(error)
        guard case .failed = f.manager.sessions[0].status else {
            return XCTFail("expected failed status")
        }
        let keyPath = FileManager.default.temporaryDirectory.appendingPathComponent("macsh-key-\(r.id.uuidString)").path
        XCTAssertFalse(FileManager.default.fileExists(atPath: keyPath))
    }

    func testShutdownAllUnmountsMountedSessions() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: s3Backend())
        try f.manager.add(r, s3Secrets: S3Secrets(accessKeyID: "AK", secretAccessKey: "SK"))
        try await f.manager.mount(remoteID: r.id)

        f.manager.shutdownAll()

        XCTAssertEqual(f.manager.sessions[0].status, .idle)
        XCTAssertEqual(f.mounter.unmounted.count, 1)
    }

    func testDeleteMountedRemoteUnmountsFirst() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: s3Backend())
        try f.manager.add(r, s3Secrets: S3Secrets(accessKeyID: "AK", secretAccessKey: "SK"))
        try await f.manager.mount(remoteID: r.id)

        try f.manager.delete(r.id)

        XCTAssertEqual(f.mounter.unmounted.count, 1)
        XCTAssertTrue(f.manager.sessions.isEmpty)
    }

    // MARK: - Auto-mount

    func testAutoMountAllReconcilesAndMountsAutoMountRemotes() async throws {
        let f = try makeFixture()
        let auto = makeRemote(name: "auto", backend: s3Backend(), autoMount: true)
        let manual = makeRemote(name: "manual", backend: s3Backend(), autoMount: false)
        let secrets = S3Secrets(accessKeyID: "AK", secretAccessKey: "SK")
        try f.manager.add(auto, s3Secrets: secrets)
        try f.manager.add(manual, s3Secrets: secrets)

        f.manager.autoMountAll()

        // autoMountAll reconciles stale mounts and mounts off the main thread, so wait for the result.
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if case .mounted = f.manager.sessions[0].status, f.mounter.reconciled.count >= 2 { break }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertEqual(Set(f.mounter.reconciled), ["auto", "manual"])
        XCTAssertEqual(f.manager.sessions[0].status, .mounted(at: "/Volumes/fake/auto"))
        XCTAssertEqual(f.manager.sessions[1].status, .idle)
    }

    func testAutoMountFailureSchedulesRetryThatShutdownCancels() async throws {
        let f = try makeFixture()
        let r = makeRemote(backend: s3Backend(), autoMount: true)
        try f.manager.add(r)   // no credentials -> every attempt fails

        f.manager.autoMountAll()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if case .failed = f.manager.sessions[0].status { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard case .failed = f.manager.sessions[0].status else {
            return XCTFail("expected failed status after first attempt")
        }
        f.manager.shutdownAll()
    }
}
