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
    public let rcloneBinary: URL
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
        let mounter = self.mounter
        let volnames = sessions.map { mounter.volumeName(from: $0.remote.name) }
        let autoMountIDs = sessions.filter { $0.remote.autoMount }.map { $0.id }
        Task { @MainActor [weak self] in
            // Reconcile all stale mounts in parallel, off the main actor.
            await withTaskGroup(of: Void.self) { group in
                for volname in volnames {
                    group.addTask { await mounter.reconcileStaleMount(volumeName: volname) }
                }
            }
            guard let self else { return }
            for id in autoMountIDs {
                self.scheduleMount(remoteID: id, attempt: 0)
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

    public func delete(_ remoteID: UUID) async throws {
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        if let session = sessions.first(where: { $0.id == remoteID }), case .mounted = session.status {
            try? await unmount(remoteID: remoteID)
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

    public func mount(remoteID: UUID) async throws {
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
                case .sshAgent:
                    // Use the explicitly configured socket; fall back to SSH_AUTH_SOCK from env.
                    let sock = sftp.sshAgentSocket
                        ?? ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"]
                    if let sock { envOverrides["SSH_AUTH_SOCK"] = sock }
                }
                bundle.sftp = SFTPSecrets(
                    password: password,
                    privateKeyPath: resolvedKeyPath,
                    keyPassphrase: try keychain.get(remoteID: remote.id, kind: .keyPassphrase)
                )
                if sftp.authKind == .password, let p = password {
                    envOverrides[RcloneConfigBuilder.passwordEnvVar(remoteID: remote.id)] =
                        try await RcloneProcess.obscure(plaintext: p, binary: rcloneBinary)
                }
                // ssh-keyscan runs off the main actor — no UI blocking
                if let verifier = hostKeyVerifier {
                    try await verifier.ensureKnown(host: sftp.host, port: sftp.port)
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
                    try await RcloneProcess.obscure(plaintext: password, binary: rcloneBinary)
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

            // Async wait — releases the main actor so the UI stays responsive while rclone starts.
            // Also detects early rclone exit so we don't wait 30s for a dead process.
            try await waitForPort(spawned.port, process: spawned.process, logURL: logURL, timeout: 30.0)

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

    public func unmount(remoteID: UUID) async throws {
        guard let session = sessions.first(where: { $0.id == remoteID }) else { return }
        retryTasks[remoteID]?.cancel()
        retryTasks[remoteID] = nil
        let mp = session.mountpoint
        let proc = session.rcloneProcess
        let keyURL = session.ephemeralKeyURL
        // Clear state immediately so the menu reflects "idle" while diskutil runs.
        session.rcloneProcess = nil
        session.mountpoint = nil
        session.ephemeralKeyURL = nil
        session.transition(to: .idle)
        // diskutil unmount blocks — run off the main actor.
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    if let mp { try self.mounter.unmount(mountpoint: mp) }
                    if let proc, proc.isRunning { proc.terminate() }
                    if let url = keyURL { try? FileManager.default.removeItem(at: url) }
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    public func shutdownAll() {
        for (_, task) in retryTasks { task.cancel() }
        retryTasks.removeAll()
        for session in sessions {
            if case .mounted = session.status {
                Task { try? await unmount(remoteID: session.id) }
            }
        }
    }

    public func logURL(for remoteID: UUID) -> URL {
        logsDir.appendingPathComponent("\(remoteID.uuidString).log")
    }

    // MARK: - Port polling (async — releases main actor between checks)

    private func waitForPort(_ port: Int, process: Process, logURL: URL, timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if isPortOpen(port) { return }
            // Detect early exit — no need to wait the full timeout for a dead process
            if !process.isRunning {
                let reason = lastCriticalLine(in: logURL)
                throw NSError(
                    domain: "macsh", code: 2,
                    userInfo: [NSLocalizedDescriptionKey: reason ?? "rclone exited unexpectedly (code \(process.terminationStatus))"]
                )
            }
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
        throw NSError(
            domain: "macsh", code: 1,
            userInfo: [NSLocalizedDescriptionKey: "rclone serve did not open port \(port) within \(Int(timeout))s"]
        )
    }

    /// Reads the last CRITICAL or ERROR line from a rclone log file for user-facing errors.
    private func lastCriticalLine(in url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let line = text.split(separator: "\n")
            .last { $0.contains("CRITICAL") || $0.contains("ERROR") }
            .map(String.init)?
            .replacingOccurrences(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} (CRITICAL|ERROR): "#,
                                   with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return line?.isEmpty == false ? line : nil
    }

    private func isPortOpen(_ port: Int) -> Bool {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { return false }
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
