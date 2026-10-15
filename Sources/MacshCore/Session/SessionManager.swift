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

    /// How long `mount` waits for rclone to start listening. Overridable for tests.
    public var portWaitTimeout: TimeInterval = 30

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
        let volnames = sessions.map { mounter.volumeName(from: $0.remote.name) }
        let mounter = self.mounter
        Task { @MainActor [weak self] in
            // pgrep / mount / diskutil: keep them off the main thread.
            try? await Self.offMain { for v in volnames { mounter.reconcileStaleMount(volumeName: v) } }
            guard let self else { return }
            for session in self.sessions where session.remote.autoMount {
                self.scheduleMount(remoteID: session.id, attempt: 0)
            }
        }
    }

    /// Runs blocking work (Process.waitUntilExit, NetFS, sockets) on a background queue so
    /// the main thread, and with it the menu bar item, stays responsive.
    nonisolated static func offMain<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(with: Result { try work() })
            }
        }
    }

    private func scheduleMount(remoteID: UUID, attempt: Int) {
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await self.mount(remoteID: remoteID)
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
            try? unmountBlocking(remoteID: remoteID)
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

    /// Key file path saved for a `.keyFile` SFTP remote (a path, not a secret), so edit
    /// forms can show it instead of asking for it again.
    public func storedKeyFilePath(for remoteID: UUID) -> String? {
        (try? keychain.get(remoteID: remoteID, kind: .privateKey)) ?? nil
    }

    /// Mounts a remote. Everything that blocks (rclone start-up, host-key scan, NetFS,
    /// mount_nfs) runs off the main thread; only state changes and dialogs use it.
    public func mount(remoteID: UUID) async throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        switch session.status {
        case .starting, .stopping: return    // an operation is already in flight
        default: break
        }
        session.transition(to: .starting)
        let mounter = self.mounter
        let rcloneBinary = self.rcloneBinary

        let remote = session.remote
        let logFile = logsDir.appendingPathComponent("\(remote.id.uuidString).log")
        var ephemeralKeyURL: URL? = nil
        var spawnedProcess: Process? = nil
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
                if sftp.authKind == .keyFile, let pp = bundle.sftp?.keyPassphrase, !pp.isEmpty {
                    // Without this, passphrase-protected keys fail with
                    // "ssh: this private key is passphrase protected".
                    envOverrides[RcloneConfigBuilder.keyPassphraseEnvVar] =
                        try await Self.offMain { try RcloneProcess.obscure(plaintext: pp, binary: rcloneBinary) }
                }
                if sftp.authKind == .password, let p = password {
                    envOverrides[RcloneConfigBuilder.passwordEnvVar(remoteID: remote.id)] =
                        try await Self.offMain { try RcloneProcess.obscure(plaintext: p, binary: rcloneBinary) }
                }
                if let verifier = hostKeyVerifier {
                    let host = sftp.host, port = sftp.port
                    let inspection = try await Self.offMain { try verifier.inspect(host: host, port: port) }
                    try verifier.resolve(inspection)     // dialog + known_hosts on the main actor
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
                    try await Self.offMain { try RcloneProcess.obscure(plaintext: password, binary: rcloneBinary) }
                remotePath = ftp.remotePath
            }

            let configText = try RcloneConfigBuilder.build(
                remote: remote,
                secrets: bundle,
                knownHostsPath: hostKeyVerifier?.knownHostsPath
            )
            let logURL = logsDir.appendingPathComponent("\(remote.id.uuidString).log")
            let tuning = remote.tuning ?? .defaults(for: remote.mountProtocol)
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
                    tuning: tuning,
                    envOverrides: envOverrides
                )
            case .nfs:
                spawned = try runner.spawnNFSServe(
                    remoteName: RcloneConfigBuilder.sectionName,
                    remotePath: remotePath,
                    configText: configText,
                    liveUpdates: remote.liveUpdates,
                    tuning: tuning,
                    envOverrides: envOverrides
                )
            }
            spawnedProcess = spawned.process
            try await waitForPort(spawned.port, process: spawned.process, timeout: portWaitTimeout)

            let mountpoint: String
            switch remote.mountProtocol {
            case .webdav:
                let (port, user, pass) = (spawned.port, spawned.user, spawned.password)
                mountpoint = try await Self.offMain {
                    try mounter.mountWebDAV(host: "127.0.0.1", port: port, baseurl: "/\(volname)", user: user, password: pass)
                }
            case .nfs:
                let (port, name) = (spawned.port, remote.name)
                mountpoint = try await Self.offMain {
                    let mp = try mounter.resolveMountpoint(name: name)
                    try mounter.mountNFS(host: "127.0.0.1", port: port, exportPath: "/", name: name, mountpoint: mp)
                    return mp
                }
            }

            session.rcloneProcess = spawned.process
            session.mountpoint = mountpoint
            session.ephemeralKeyURL = ephemeralKeyURL
            session.transition(to: .mounted(at: mountpoint))
        } catch {
            if let url = ephemeralKeyURL { try? FileManager.default.removeItem(at: url) }
            if let proc = spawnedProcess, proc.isRunning { proc.terminate() }
            var reason = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            // rclone's own explanation (bad key, auth failure, ...) only goes to its log.
            if let tail = Self.logTail(of: logFile) { reason += "\n" + tail }
            session.transition(to: .failed(reason: reason))
            throw error
        }
    }

    /// Unmounts a remote without blocking the main thread.
    public func unmount(remoteID: UUID) async throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        switch session.status {
        case .starting, .stopping: return
        default: break
        }
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        let previous = session.status
        session.transition(to: .stopping)
        if let mp = session.mountpoint {
            let mounter = self.mounter
            do { try await Self.offMain { try mounter.unmount(mountpoint: mp) } }
            catch {
                session.transition(to: previous)    // still mounted (e.g. busy)
                throw error
            }
        }
        finishUnmount(session)
    }

    /// Synchronous variant for app quit and remote deletion, where there is no run loop
    /// left to wait on.
    public func unmountBlocking(remoteID: UUID) throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        if let mp = session.mountpoint {
            try mounter.unmount(mountpoint: mp)
        }
        finishUnmount(session)
    }

    private func finishUnmount(_ session: RemoteSession) {
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
                try? unmountBlocking(remoteID: session.id)
            }
        }
    }

    public func logURL(for remoteID: UUID) -> URL {
        logsDir.appendingPathComponent("\(remoteID.uuidString).log")
    }

    /// Last `lines` non-empty lines of an rclone log, or nil if it is missing/empty.
    static func logTail(of url: URL, lines: Int = 3) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let tail = text.split(separator: "\n").map(String.init)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            .suffix(lines)
        return tail.isEmpty ? nil : tail.joined(separator: "\n")
    }

    private func waitForPort(_ port: Int, process: Process, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if Self.canConnect(port: port) { return }
            if !process.isRunning {
                throw NSError(domain: "macsh", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "rclone exited before it started listening (exit \(process.terminationStatus))"])
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw NSError(domain: "macsh", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "rclone serve did not open port \(port) within \(Int(timeout))s"])
    }

    /// One non-blocking-in-practice TCP connect to 127.0.0.1 (refused or accepted at once).
    nonisolated static func canConnect(port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        if sock < 0 { return false }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }
}
