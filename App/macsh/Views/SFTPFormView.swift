import SwiftUI
import AppKit
import MacshCore

struct SFTPFormDraft {
    var name: String = ""
    var host: String = ""
    var port: String = "22"
    var user: String = ""
    var remotePath: String = ""
    var authKind: SFTPAuthKind = .password
    var password: String = ""
    var keyFilePath: String = ""
    var keyPassphrase: String = ""
    var generatedKeyPair: GeneratedKeyPair? = nil
    var autoMount: Bool = true
    var liveUpdates: Bool = true
    var mountProtocol: MountProtocol = .webdav
    /// nil = inherit SSH_AUTH_SOCK from env (default). Set by agent picker after test.
    var sshAgentSocket: String? = nil

    /// Populated when editing an existing remote. Skipped when adding.
    var existingRemoteID: UUID? = nil

    init() {}

    /// Pre-fill from an existing remote. Secret fields (password, key passphrase) are
    /// intentionally left blank — the form contract is "blank means keep existing".
    init(editing remote: Remote) {
        self.existingRemoteID = remote.id
        self.name = remote.name
        self.autoMount = remote.autoMount
        self.liveUpdates = remote.liveUpdates
        self.mountProtocol = remote.mountProtocol
        if case .sftp(let cfg) = remote.backend {
            self.host = cfg.host
            self.port = String(cfg.port)
            self.user = cfg.user
            self.remotePath = cfg.remotePath
            self.authKind = cfg.authKind
            self.sshAgentSocket = cfg.sshAgentSocket
        }
    }

    mutating func apply(sshConfigHost h: SSHConfigHost) {
        name = h.alias
        host = h.hostname
        port = String(h.port)
        if let u = h.user { user = u }
        if let keyFile = h.identityFile {
            authKind = .keyFile
            keyFilePath = keyFile
        }
    }

    func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name required" }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host required" }
        guard let p = Int(port), (1...65535).contains(p) else { return "Port must be 1-65535" }
        if user.trimmingCharacters(in: .whitespaces).isEmpty { return "User required" }
        let isEditing = existingRemoteID != nil
        switch authKind {
        case .password:
            if password.isEmpty && !isEditing { return "Password required" }
        case .keyFile:
            if keyFilePath.isEmpty { return "Key file required" }
        case .generatedKey:
            // On edit, the existing key in keychain stays unless user regenerates.
            if generatedKeyPair == nil && !isEditing { return "Generate the key first" }
        case .sshAgent:
            break
        }
        return nil
    }

    func toRemoteAndSecrets() -> (Remote, SFTPSecrets) {
        let remote = Remote(
            id: existingRemoteID ?? UUID(),
            name: name,
            backend: .sftp(SFTPConfig(
                host: host, port: Int(port) ?? 22, user: user,
                remotePath: remotePath, authKind: authKind,
                sshAgentSocket: authKind == .sshAgent ? sshAgentSocket : nil
            )),
            mountProtocol: mountProtocol,
            autoMount: autoMount,
            liveUpdates: liveUpdates
        )
        let secrets: SFTPSecrets
        switch authKind {
        case .password:
            secrets = SFTPSecrets(
                password: password.isEmpty ? nil : password,
                privateKeyPath: nil,
                keyPassphrase: nil
            )
        case .keyFile:
            secrets = SFTPSecrets(
                password: nil,
                privateKeyPath: keyFilePath.isEmpty ? nil : keyFilePath,
                keyPassphrase: keyPassphrase.isEmpty ? nil : keyPassphrase
            )
        case .generatedKey:
            secrets = SFTPSecrets(
                password: nil,
                privateKeyPath: generatedKeyPair?.privateKeyPEM,
                keyPassphrase: nil
            )
        case .sshAgent:
            secrets = SFTPSecrets(password: nil, privateKeyPath: nil, keyPassphrase: nil)
        }
        return (remote, secrets)
    }
}

private struct SSHConfigPickerData: Identifiable {
    let id = UUID()
    let hosts: [SSHConfigHost]
}

private enum ConnectionTestState: Equatable {
    case idle
    case running
    case success(String)
    case failure(String)
}

private enum AgentTestStatus: Equatable { case testing, working, failed }

struct SFTPFormView: View {
    @Binding var draft: SFTPFormDraft
    let rcloneBinary: URL
    @State private var showGenerateSheet = false
    @State private var sshConfigPickerData: SSHConfigPickerData? = nil
    @State private var connectionTest: ConnectionTestState = .idle
    @State private var agentCandidates: [SSHAgentCandidate] = []
    @State private var agentStatuses: [String: AgentTestStatus] = [:]

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    TextField("", text: $draft.name, prompt: Text("My laptop"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Host") {
                    TextField("", text: $draft.host, prompt: Text("example.com or 192.168.0.10"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("", text: $draft.port, prompt: Text("22"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
                LabeledContent("User") {
                    TextField("", text: $draft.user, prompt: Text("alice"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Path") {
                    TextField("", text: $draft.remotePath, prompt: Text("leave empty for home, or /var/www"))
                        .textFieldStyle(.roundedBorder)
                }
            } header: {
                HStack {
                    Text("Connection")
                    Spacer()
                    Button("From SSH Config…") {
                        let hosts = SSHConfigParser.defaultConfigHosts()
                        if !hosts.isEmpty {
                            sshConfigPickerData = SSHConfigPickerData(hosts: hosts)
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .sheet(item: $sshConfigPickerData) { data in
                SSHConfigPickerSheet(hosts: data.hosts) { host in
                    draft.apply(sshConfigHost: host)
                    sshConfigPickerData = nil
                }
            }

            Section("Authentication") {
                LabeledContent("Method") {
                    Picker("", selection: $draft.authKind) {
                        Text("Password").tag(SFTPAuthKind.password)
                        Text("Key file").tag(SFTPAuthKind.keyFile)
                        Text("Generate").tag(SFTPAuthKind.generatedKey)
                        Text("SSH Agent").tag(SFTPAuthKind.sshAgent)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                switch draft.authKind {
                case .password:
                    LabeledContent("Password") {
                        SecureField(
                            "",
                            text: $draft.password,
                            prompt: Text(draft.existingRemoteID != nil ? "Leave blank to keep" : "")
                        ).textFieldStyle(.roundedBorder)
                    }
                case .keyFile:
                    LabeledContent("Key file") {
                        HStack(spacing: 6) {
                            TextField("", text: $draft.keyFilePath,
                                      prompt: Text("/path/to/id_ed25519"))
                                .textFieldStyle(.roundedBorder)
                            Button("Choose…") {
                                let panel = NSOpenPanel()
                                panel.canChooseFiles = true
                                panel.canChooseDirectories = false
                                panel.allowsMultipleSelection = false
                                panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser
                                    .appendingPathComponent(".ssh")
                                if panel.runModal() == .OK, let url = panel.url {
                                    draft.keyFilePath = url.path
                                }
                            }
                        }
                    }
                    LabeledContent("Passphrase") {
                        SecureField("", text: $draft.keyPassphrase, prompt: Text("If any"))
                            .textFieldStyle(.roundedBorder)
                    }
                case .generatedKey:
                    LabeledContent("Keypair") {
                        HStack {
                            if let kp = draft.generatedKeyPair {
                                Text(kp.fingerprintSHA256)
                                    .font(.caption.monospaced())
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer()
                                Button("Regenerate…") { showGenerateSheet = true }
                            } else {
                                Button("Generate ed25519…") { showGenerateSheet = true }
                                Spacer()
                            }
                        }
                    }
                    .sheet(isPresented: $showGenerateSheet) {
                        GenerateKeySheet { kp in draft.generatedKeyPair = kp }
                    }
                case .sshAgent:
                    LabeledContent("Agent") {
                        VStack(alignment: .leading, spacing: 4) {
                            if agentCandidates.isEmpty {
                                Text("Scanning for agents…")
                                    .foregroundStyle(.secondary)
                                    .font(.caption)
                            } else {
                                agentRow(name: "Auto (SSH_AUTH_SOCK)", hint: "Inherit from environment", socketPath: nil)
                                Divider().padding(.vertical, 2)
                                ForEach(sortedAgentCandidates) { c in
                                    agentRow(name: c.name, hint: c.displayPath, socketPath: c.path)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            Section {
                LabeledContent("") {
                    HStack(spacing: 8) {
                        Button {
                            connectionTest = .idle
                            Task { await runConnectionTest() }
                        } label: {
                            if connectionTest == .running {
                                HStack(spacing: 6) {
                                    ProgressView().controlSize(.small)
                                    Text("Testing…")
                                }
                            } else {
                                Text("Test Connection")
                            }
                        }
                        .disabled(
                            connectionTest == .running ||
                            draft.host.trimmingCharacters(in: .whitespaces).isEmpty ||
                            draft.user.trimmingCharacters(in: .whitespaces).isEmpty
                        )
                        Spacer()
                        switch connectionTest {
                        case .idle: EmptyView()
                        case .running: EmptyView()
                        case .success:
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .failure:
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                        }
                    }
                }
                if case .success(let msg) = connectionTest {
                    Text(msg)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if case .failure(let log) = connectionTest {
                    ScrollView(.vertical) {
                        Text(log)
                            .font(.caption.monospaced())
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 100)
                }
            } header: {
                Text("Test")
            }

            Section("Mount") {
                LabeledContent("Protocol") {
                    Picker("", selection: $draft.mountProtocol) {
                        Text("WebDAV").tag(MountProtocol.webdav)
                        Text("NFS").tag(MountProtocol.nfs)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                LabeledContent("Options") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("Mount automatically at login", isOn: $draft.autoMount)
                        Toggle("Live updates", isOn: $draft.liveUpdates)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .task {
            // Filesystem-only scan — fast, safe on main actor
            agentCandidates = SSHAgentScanner.scan()
            // Pre-select configured socket if it's still present
            if let configured = draft.sshAgentSocket,
               !agentCandidates.contains(where: { $0.path == configured }) {
                draft.sshAgentSocket = nil
            }
        }
    }

    // MARK: - Agent picker helpers

    private var sortedAgentCandidates: [SSHAgentCandidate] {
        agentCandidates.sorted { a, b in
            let aOk = agentStatuses[a.path] == .working
            let bOk = agentStatuses[b.path] == .working
            if aOk != bOk { return aOk }
            return false
        }
    }

    @ViewBuilder
    private func agentRow(name: String, hint: String, socketPath: String?) -> some View {
        let isSelected = draft.sshAgentSocket == socketPath
        let status = socketPath.flatMap { agentStatuses[$0] }
        Button { draft.sshAgentSocket = socketPath } label: {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark" : "")
                    .frame(width: 14)
                    .foregroundStyle(Color.accentColor)
                    .font(.caption.bold())
                VStack(alignment: .leading, spacing: 1) {
                    Text(name).fontWeight(isSelected ? .semibold : .regular)
                    Text(hint).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                agentStatusDot(status)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func agentStatusDot(_ status: AgentTestStatus?) -> some View {
        switch status {
        case .testing: ProgressView().controlSize(.mini)
        case .working: Image(systemName: "circle.fill").foregroundStyle(.green).font(.caption2)
        case .failed:  Image(systemName: "circle.fill").foregroundStyle(.secondary).font(.caption2)
        case nil:      EmptyView()
        }
    }

    private func runConnectionTest() async {
        connectionTest = .running
        let host = draft.host.trimmingCharacters(in: .whitespaces)
        let port = Int(draft.port) ?? 22
        let user = draft.user.trimmingCharacters(in: .whitespaces)

        if draft.authKind == .sshAgent {
            await runAgentTest(host: host, port: port, user: user)
            return
        }

        let result: (Bool, String) = await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                switch draft.authKind {
                case .password, .generatedKey:
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
                    p.arguments = ["-z", "-w", "5", host, String(port)]
                    p.standardOutput = Pipe(); p.standardError = Pipe()
                    do { try p.run() } catch { cont.resume(returning: (false, error.localizedDescription)); return }
                    p.waitUntilExit()
                    if p.terminationStatus == 0 {
                        cont.resume(returning: (true, "Port \(port) is reachable (auth not tested — \(draft.authKind == .password ? "password" : "generated key") requires a live connection)"))
                    } else {
                        cont.resume(returning: (false, "Cannot reach \(host):\(port) — check host and port"))
                    }

                case .keyFile:
                    var args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                                "-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR",
                                "-p", String(port)]
                    if !draft.keyFilePath.isEmpty {
                        args += ["-i", draft.keyFilePath, "-o", "IdentitiesOnly=yes"]
                    }
                    args += ["\(user)@\(host)", "echo __macsh_ok__"]
                    let p = Process()
                    p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                    p.arguments = args
                    p.environment = ProcessInfo.processInfo.environment
                    let outPipe = Pipe(); let errPipe = Pipe()
                    p.standardOutput = outPipe; p.standardError = errPipe
                    do { try p.run() } catch { cont.resume(returning: (false, error.localizedDescription)); return }
                    p.waitUntilExit()
                    let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                    guard out.contains("__macsh_ok__") else {
                        let msg = err.trimmingCharacters(in: .whitespacesAndNewlines)
                        cont.resume(returning: (false, msg.isEmpty ? "Exit code \(p.terminationStatus)" : msg))
                        return
                    }
                    // SSH ok — now verify rclone
                    let (rOk, rMsg) = Self.rcloneTest(
                        rclone: rcloneBinary, socketPath: nil,
                        host: host, port: port, user: user, authKind: .keyFile, keyFilePath: draft.keyFilePath
                    )
                    if rOk {
                        cont.resume(returning: (true, "SSH ✓  rclone ✓  as \(user)@\(host):\(port)"))
                    } else {
                        cont.resume(returning: (false, "SSH ok, but rclone failed:\n\(rMsg)"))
                    }

                case .sshAgent: break  // handled above
                }
            }
        }
        connectionTest = result.0 ? .success(result.1) : .failure(result.1)
    }

    /// Tests every discovered agent against the server, marks statuses, sorts working
    /// ones to the top, and auto-selects the first that authenticates successfully.
    private func runAgentTest(host: String, port: Int, user: String) async {
        let candidates = agentCandidates
        guard !candidates.isEmpty else {
            connectionTest = .failure("No SSH agents found. Is your password manager running?")
            return
        }

        // Mark all as testing
        for c in candidates { agentStatuses[c.path] = .testing }

        var firstWorking: SSHAgentCandidate? = nil

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let group = DispatchGroup()
                var workingPaths = Set<String>()
                let lock = NSLock()

                for candidate in candidates {
                    group.enter()
                    DispatchQueue.global(qos: .userInitiated).async {
                        let ok = Self.sshTest(socketPath: candidate.path, host: host, port: port, user: user)
                        lock.lock()
                        if ok { workingPaths.insert(candidate.path) }
                        lock.unlock()
                        group.leave()
                    }
                }

                group.wait()

                // Update statuses and pick first working (preserving original order)
                let winner = candidates.first { workingPaths.contains($0.path) }
                DispatchQueue.main.sync {
                    for c in candidates {
                        agentStatuses[c.path] = workingPaths.contains(c.path) ? .working : .failed
                    }
                    firstWorking = winner
                    if winner == nil {
                        connectionTest = .failure("No agent could authenticate to \(host):\(port)")
                    }
                }

                // Phase 2: verify rclone can also connect with the winning agent
                if let winner {
                    let rclone = rcloneBinary
                    let (ok, msg) = Self.rcloneTest(
                        rclone: rclone, socketPath: winner.path,
                        host: host, port: port, user: user, authKind: .sshAgent, keyFilePath: ""
                    )
                    DispatchQueue.main.sync {
                        draft.sshAgentSocket = winner.path
                        if ok {
                            connectionTest = .success("SSH ✓  rclone ✓  via \(winner.name) — \(user)@\(host):\(port)")
                        } else {
                            connectionTest = .failure("SSH ok via \(winner.name), but rclone failed:\n\(msg)")
                        }
                    }
                }

                cont.resume()
            }
        }
        _ = firstWorking  // silence unused warning
    }

    private static func rcloneTest(
        rclone: URL, socketPath: String?,
        host: String, port: Int, user: String,
        authKind: SFTPAuthKind, keyFilePath: String
    ) -> (Bool, String) {
        var lines = ["[r]", "type = sftp", "host = \(host)", "port = \(port)", "user = \(user)"]
        switch authKind {
        case .sshAgent:  lines.append("use_agent = true")
        case .keyFile:   if !keyFilePath.isEmpty { lines.append("key_file = \(keyFilePath)") }
        default: return (false, "rclone test not applicable for this auth method")
        }
        let configText = lines.joined(separator: "\n") + "\n"
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-rclone-test-\(UUID().uuidString)")
        guard (try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)) != nil else {
            return (false, "Could not create temp dir")
        }
        let configURL = tmpDir.appendingPathComponent("rclone.conf")
        guard (try? configText.write(to: configURL, atomically: true, encoding: .utf8)) != nil else {
            return (false, "Could not write temp config")
        }
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let p = Process()
        p.executableURL = rclone
        p.arguments = ["lsd", "--config", configURL.path, "r:",
                       "--contimeout", "10s", "--timeout", "15s"]
        var env = ProcessInfo.processInfo.environment
        if let sock = socketPath { env["SSH_AUTH_SOCK"] = sock }
        p.environment = env
        let errPipe = Pipe()
        p.standardOutput = Pipe()
        p.standardError = errPipe
        guard (try? p.run()) != nil else { return (false, "Failed to launch rclone") }
        p.waitUntilExit()

        if p.terminationStatus == 0 { return (true, "") }
        let raw = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let msg = raw.split(separator: "\n")
            .filter { $0.contains("CRITICAL") || $0.contains("ERROR") }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (false, msg.isEmpty ? "rclone exit \(p.terminationStatus)" : msg)
    }

    private static func sshTest(socketPath: String, host: String, port: Int, user: String) -> Bool {
        let args = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=10",
                    "-o", "StrictHostKeyChecking=no", "-o", "LogLevel=ERROR",
                    "-o", "IdentitiesOnly=yes",
                    "-p", String(port), "\(user)@\(host)", "echo __macsh_ok__"]
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["SSH_AUTH_SOCK"] = socketPath
        p.environment = env
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return false }
        p.waitUntilExit()
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.contains("__macsh_ok__")
    }
}

private struct SSHConfigPickerSheet: View {
    let hosts: [SSHConfigHost]
    let onSelect: (SSHConfigHost) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Text("Select SSH Host")
                .font(.headline)
                .padding()

            Divider()

            List(hosts) { host in
                Button {
                    onSelect(host)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(host.alias).fontWeight(.medium)
                        HStack(spacing: 6) {
                            Text("\(host.hostname):\(host.port)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let user = host.user {
                                Text("·").foregroundStyle(.secondary).font(.caption)
                                Text(user).font(.caption).foregroundStyle(.secondary)
                            }
                            if host.identityFile != nil {
                                Text("·").foregroundStyle(.secondary).font(.caption)
                                Text("key").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .listStyle(.plain)

            Divider()

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
        }
        .frame(width: 340, height: 320)
    }
}
