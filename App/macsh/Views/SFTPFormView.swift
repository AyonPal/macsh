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
                remotePath: remotePath, authKind: authKind
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

struct SFTPFormView: View {
    @Binding var draft: SFTPFormDraft
    @State private var showGenerateSheet = false
    @State private var showSSHConfigPicker = false
    @State private var sshConfigHosts: [SSHConfigHost] = []

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
                            sshConfigHosts = hosts
                            showSSHConfigPicker = true
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
            .sheet(isPresented: $showSSHConfigPicker) {
                SSHConfigPickerSheet(hosts: sshConfigHosts) { host in
                    draft.apply(sshConfigHost: host)
                    showSSHConfigPicker = false
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
                        Text("Uses the system SSH agent (SSH_AUTH_SOCK).")
                            .foregroundStyle(.secondary)
                    }
                }
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
