import Foundation
import Combine
import Darwin

@MainActor
public final class SessionManager: ObservableObject {
    @Published public private(set) var sessions: [RemoteSession] = []

    private let store: RemoteStore
    private let keychain: KeychainService
    private let mounter: Mounter
    private let logsDir: URL
    private let rcloneBinary: URL
    private let hostKeyVerifier: HostKeyVerifier?

    private var retryTasks: [UUID: Task<Void, Never>] = [:]
    private var sessionCancellables: [UUID: AnyCancellable] = [:]

    public init(
        store: RemoteStore,
        keychain: KeychainService,
        mounter: Mounter,
        logsDir: URL,
        rcloneBinary: URL,
        hostKeyVerifier: HostKeyVerifier? = nil
    ) {
        self.store = store
        self.keychain = keychain
        self.mounter = mounter
        self.logsDir = logsDir
        self.rcloneBinary = rcloneBinary
        self.hostKeyVerifier = hostKeyVerifier
        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)
    }

    public func reload() throws {
        let remotes = try store.load()
        let existingByID = Dictionary(uniqueKeysWithValues: sessions.map { ($0.id, $0) })
        let newSessions = remotes.map { existingByID[$0.id] ?? RemoteSession(remote: $0) }
        sessions = newSessions
        // Re-subscribe each session's status changes so the menu (which subscribes to
        // $sessions) rebuilds when a status flips. Without this, mount → unmount label
        // never updates because the array's reference doesn't change on transition.
        sessionCancellables.removeAll()
        for s in newSessions {
            sessionCancellables[s.id] = s.$status
                .dropFirst()
                .sink { [weak self] _ in
                    guard let self else { return }
                    // Re-publish the same array so subscribers of $sessions wake up.
                    self.sessions = self.sessions
                }
        }
    }

    /// Called once at app launch after `reload()` to mount every remote with autoMount=true.
    /// First reconciles stale mounts left behind by a prior instance that died via
    /// SIGKILL/crash — without this, every relaunch would pile up `<name>-1`,
    /// `<name>-2`, … entries in /Volumes since NetFS auto-numbers collisions.
    public func autoMountAll() {
        for session in sessions {
            let volname = mounter.volumeName(from: session.remote.name)
            mounter.reconcileStaleMount(volumeName: volname)
        }
        for session in sessions where session.remote.autoMount {
            scheduleMount(remoteID: session.id, attempt: 0)
        }
    }

    private func scheduleMount(remoteID: UUID, attempt: Int) {
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try self.mount(remoteID: remoteID)
                self.retryTasks[remoteID] = nil
            } catch {
                let nextAttempt = attempt + 1
                let delay = Self.backoffDelay(attempt: nextAttempt)
                guard delay > 0 else { return }
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if !Task.isCancelled {
                    self.scheduleMount(remoteID: remoteID, attempt: nextAttempt)
                }
            }
        }
    }

    /// Exponential backoff: 1s, 5s, 30s, then 5min cap.
    static func backoffDelay(attempt: Int) -> TimeInterval {
        switch attempt {
        case 1: return 1
        case 2: return 5
        case 3: return 30
        case 4...: return 300
        default: return 0
        }
    }

    public func add(_ remote: Remote, sftpSecrets: SFTPSecrets? = nil, s3Secrets: S3Secrets? = nil, ftpSecrets: FTPSecrets? = nil) throws {
        if let s = sftpSecrets {
            if let pwd = s.password { try keychain.set(remoteID: remote.id, kind: .password, value: pwd) }
            if let pp = s.keyPassphrase { try keychain.set(remoteID: remote.id, kind: .keyPassphrase, value: pp) }
            if let keyPath = s.privateKeyPath { try keychain.set(remoteID: remote.id, kind: .privateKey, value: keyPath) }
        }
        if let s = s3Secrets {
            try keychain.set(remoteID: remote.id, kind: .s3AccessKeyID, value: s.accessKeyID)
            try keychain.set(remoteID: remote.id, kind: .s3SecretAccessKey, value: s.secretAccessKey)
        }
        if let s = ftpSecrets {
            try keychain.set(remoteID: remote.id, kind: .password, value: s.password)
        }
        var all = try store.load()
        all.append(remote)
        try store.save(all)
        try reload()
    }

    /// Updates an existing remote in `remotes.json`. Backend type cannot change.
    /// Secret fields (`SFTPSecrets.password`, `S3Secrets.accessKeyID`/`secretAccessKey`,
    /// `FTPSecrets.password`) are interpreted as "blank means keep existing": only
    /// non-nil and non-empty values overwrite the keychain. The session reference
    /// is preserved so an in-flight `.starting` status survives the update.
    public func update(_ remote: Remote, sftpSecrets: SFTPSecrets? = nil, s3Secrets: S3Secrets? = nil, ftpSecrets: FTPSecrets? = nil) throws {
        if let s = sftpSecrets {
            if let pwd = s.password, !pwd.isEmpty { try keychain.set(remoteID: remote.id, kind: .password, value: pwd) }
            if let pp = s.keyPassphrase, !pp.isEmpty { try keychain.set(remoteID: remote.id, kind: .keyPassphrase, value: pp) }
            if let keyPath = s.privateKeyPath, !keyPath.isEmpty { try keychain.set(remoteID: remote.id, kind: .privateKey, value: keyPath) }
        }
        if let s = s3Secrets {
            if !s.accessKeyID.isEmpty { try keychain.set(remoteID: remote.id, kind: .s3AccessKeyID, value: s.accessKeyID) }
            if !s.secretAccessKey.isEmpty { try keychain.set(remoteID: remote.id, kind: .s3SecretAccessKey, value: s.secretAccessKey) }
        }
        if let s = ftpSecrets, !s.password.isEmpty {
            try keychain.set(remoteID: remote.id, kind: .password, value: s.password)
        }
        var all = try store.load()
        guard let idx = all.firstIndex(where: { $0.id == remote.id }) else {
            throw NSError(domain: "macsh", code: 2, userInfo: [NSLocalizedDescriptionKey: "Remote not found"])
        }
        all[idx] = remote
        try store.save(all)
        // Mutate the existing RemoteSession's `remote` in place rather than recreating
        // it, so any subscribers (and the session's status) are preserved. Then re-emit.
        if let s = sessions.first(where: { $0.id == remote.id }) {
            s.remote = remote
            sessions = sessions
        } else {
            try reload()
        }
    }

    public func delete(_ remoteID: UUID) throws {
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        if let session = sessions.first(where: { $0.id == remoteID }), case .mounted = session.status {
            try? unmount(remoteID: remoteID)
        }
        try? keychain.delete(remoteID: remoteID, kind: .password)
        try? keychain.delete(remoteID: remoteID, kind: .keyPassphrase)
        try? keychain.delete(remoteID: remoteID, kind: .privateKey)
        try? keychain.delete(remoteID: remoteID, kind: .localServePassword)
        var all = try store.load()
        all.removeAll { $0.id == remoteID }
        try store.save(all)
        try reload()
    }

    public func mount(remoteID: UUID) throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        session.transition(to: .starting)

        let remote = session.remote
        var ephemeralKeyURL: URL? = nil
        var envOverrides: [String: String] = [:]
        var bundle = BackendSecrets()
        var remotePath: String

        do {
            switch remote.backend {
            case .sftp(let sftp):
                let password = try keychain.get(remoteID: remote.id, kind: .password)
                var resolvedKeyPath: String? = nil
                switch sftp.authKind {
                case .password: break
                case .keyFile:
                    resolvedKeyPath = try keychain.get(remoteID: remote.id, kind: .privateKey)
                case .generatedKey:
                    if let pem = try keychain.get(remoteID: remote.id, kind: .privateKey) {
                        let url = FileManager.default.temporaryDirectory
                            .appendingPathComponent("macsh-key-\(remote.id.uuidString)")
                        try pem.write(to: url, atomically: true, encoding: .utf8)
                        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                        ephemeralKeyURL = url
                        resolvedKeyPath = url.path
                    }
                }
                bundle.sftp = SFTPSecrets(
                    password: password,
                    privateKeyPath: resolvedKeyPath,
                    keyPassphrase: try keychain.get(remoteID: remote.id, kind: .keyPassphrase)
                )
                if sftp.authKind == .password, let p = password {
                    envOverrides[RcloneConfigBuilder.passwordEnvVar(remoteID: remote.id)] =
                        try RcloneProcess.obscure(plaintext: p, binary: rcloneBinary)
                }
                if let verifier = hostKeyVerifier {
                    try verifier.ensureKnown(host: sftp.host, port: sftp.port)
                }
                remotePath = sftp.remotePath

            case .s3(let s3):
                guard let access = try keychain.get(remoteID: remote.id, kind: .s3AccessKeyID),
                      let secret = try keychain.get(remoteID: remote.id, kind: .s3SecretAccessKey) else {
                    throw RcloneConfigError.missingS3Credentials
                }
                bundle.s3 = S3Secrets(accessKeyID: access, secretAccessKey: secret)
                envOverrides[RcloneConfigBuilder.s3SecretEnvVar(remoteID: remote.id)] = secret
                remotePath = s3.prefix.isEmpty ? s3.bucket : "\(s3.bucket)/\(s3.prefix)"

            case .ftp(let ftp):
                guard let password = try keychain.get(remoteID: remote.id, kind: .password) else {
                    throw RcloneConfigError.missingFTPPassword
                }
                bundle.ftp = FTPSecrets(password: password)
                envOverrides[RcloneConfigBuilder.passwordEnvVar(remoteID: remote.id)] =
                    try RcloneProcess.obscure(plaintext: password, binary: rcloneBinary)
                remotePath = ftp.remotePath
            }

            let configText = try RcloneConfigBuilder.build(
                remote: remote,
                secrets: bundle,
                knownHostsPath: hostKeyVerifier?.knownHostsPath
            )
            let logURL = logsDir.appendingPathComponent("\(remote.id.uuidString).log")
            let runner = RcloneProcess(binary: rcloneBinary, logFile: logURL)
            let volname = mounter.volumeName(from: remote.name)
            let spawned: RcloneProcess.Spawned
            switch remote.mountProtocol {
            case .webdav:
                spawned = try runner.spawnWebDAVServe(
                    remoteName: RcloneConfigBuilder.sectionName,
                    remotePath: remotePath,
                    configText: configText,
                    baseurl: "/\(volname)",
                    liveUpdates: remote.liveUpdates,
                    envOverrides: envOverrides
                )
            case .nfs:
                spawned = try runner.spawnNFSServe(
                    remoteName: RcloneConfigBuilder.sectionName,
                    remotePath: remotePath,
                    configText: configText,
                    liveUpdates: remote.liveUpdates,
                    envOverrides: envOverrides
                )
            }
            try waitForPort(spawned.port, timeout: 5.0)

            let mountpoint: String
            switch remote.mountProtocol {
            case .webdav:
                mountpoint = try mounter.mountWebDAV(
                    host: "127.0.0.1",
                    port: spawned.port,
                    baseurl: "/\(volname)",
                    user: spawned.user,
                    password: spawned.password
                )
            case .nfs:
                let mp = try mounter.resolveMountpoint(name: remote.name)
                try mounter.mountNFS(host: "127.0.0.1", port: spawned.port, exportPath: "/", name: remote.name, mountpoint: mp)
                mountpoint = mp
            }

            session.rcloneProcess = spawned.process
            session.mountpoint = mountpoint
            session.ephemeralKeyURL = ephemeralKeyURL
            session.transition(to: .mounted(at: mountpoint))
        } catch {
            if let url = ephemeralKeyURL { try? FileManager.default.removeItem(at: url) }
            session.transition(to: .failed(reason: String(describing: error)))
            throw error
        }
    }

    public func unmount(remoteID: UUID) throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        if let mp = session.mountpoint {
            try mounter.unmount(mountpoint: mp)
        }
        if let proc = session.rcloneProcess, proc.isRunning {
            proc.terminate()
        }
        if let url = session.ephemeralKeyURL {
            try? FileManager.default.removeItem(at: url)
        }
        session.rcloneProcess = nil
        session.mountpoint = nil
        session.ephemeralKeyURL = nil
        session.transition(to: .idle)
    }

    public func shutdownAll() {
        for (_, task) in retryTasks { task.cancel() }
        retryTasks.removeAll()
        for session in sessions {
            if case .mounted = session.status {
                try? unmount(remoteID: session.id)
            }
        }
    }

    public func logURL(for remoteID: UUID) -> URL {
        logsDir.appendingPathComponent("\(remoteID.uuidString).log")
    }

    private func waitForPort(_ port: Int, timeout: TimeInterval) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            if sock < 0 { Thread.sleep(forTimeInterval: 0.1); continue }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(sock)
            if result == 0 { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw NSError(domain: "macsh", code: 1, userInfo: [NSLocalizedDescriptionKey: "rclone serve did not open port \(port) within \(timeout)s"])
    }
}
