import SwiftUI
import MacshCore

struct FTPFormDraft {
    var name: String = ""
    var host: String = ""
    var port: String = "21"
    var user: String = ""
    var password: String = ""
    var remotePath: String = "/"
    var tlsMode: FTPTLSMode = .off
    var autoMount: Bool = true
    var liveUpdates: Bool = true
    var mountProtocol: MountProtocol = .webdav
    var existingRemoteID: UUID? = nil

    init() {}

    init(editing remote: Remote) {
        self.existingRemoteID = remote.id
        self.name = remote.name
        self.autoMount = remote.autoMount
        self.liveUpdates = remote.liveUpdates
        self.mountProtocol = remote.mountProtocol
        if case .ftp(let cfg) = remote.backend {
            self.host = cfg.host
            self.port = String(cfg.port)
            self.user = cfg.user
            self.remotePath = cfg.remotePath
            self.tlsMode = cfg.tlsMode
        }
    }

    func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name required" }
        if host.trimmingCharacters(in: .whitespaces).isEmpty { return "Host required" }
        guard let p = Int(port), (1...65535).contains(p) else { return "Port must be 1-65535" }
        if user.trimmingCharacters(in: .whitespaces).isEmpty { return "User required" }
        if password.isEmpty && existingRemoteID == nil { return "Password required" }
        return nil
    }

    func toRemoteAndSecrets() -> (Remote, FTPSecrets) {
        let remote = Remote(
            id: existingRemoteID ?? UUID(),
            name: name,
            backend: .ftp(FTPConfig(
                host: host,
                port: Int(port) ?? 21,
                user: user,
                remotePath: remotePath,
                tlsMode: tlsMode
            )),
            mountProtocol: mountProtocol,
            autoMount: autoMount,
            liveUpdates: liveUpdates
        )
        return (remote, FTPSecrets(password: password))
    }
}

struct FTPFormView: View {
    @Binding var draft: FTPFormDraft

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Name") {
                    TextField("", text: $draft.name, prompt: Text("My FTP"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Host") {
                    TextField("", text: $draft.host, prompt: Text("ftp.example.com"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Port") {
                    TextField("", text: $draft.port, prompt: Text("21"))
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 80)
                }
                LabeledContent("User") {
                    TextField("", text: $draft.user, prompt: Text("user"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Password") {
                    SecureField("", text: $draft.password,
                                prompt: Text(draft.existingRemoteID != nil ? "Leave blank to keep" : ""))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Path") {
                    TextField("", text: $draft.remotePath, prompt: Text("/"))
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Security") {
                LabeledContent("TLS") {
                    Picker("", selection: $draft.tlsMode) {
                        Text("Off").tag(FTPTLSMode.off)
                        Text("Explicit").tag(FTPTLSMode.explicit)
                        Text("Implicit").tag(FTPTLSMode.implicit)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: draft.tlsMode) { _, mode in
                        if mode == .implicit && draft.port == "21" { draft.port = "990" }
                        if mode != .implicit && draft.port == "990" { draft.port = "21" }
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
