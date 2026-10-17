import SwiftUI
import MacshCore

/// Form state for the "Other rclone backend" escape hatch.
struct RawFormDraft {
    var name: String = ""
    var input = RawBackendInput()
    var autoMount: Bool = true
    var liveUpdates: Bool = true
    var mountProtocol: MountProtocol = .webdav
    var existingRemoteID: UUID? = nil

    init() {}

    init(editing remote: Remote) {
        existingRemoteID = remote.id
        name = remote.name
        autoMount = remote.autoMount
        liveUpdates = remote.liveUpdates
        mountProtocol = remote.mountProtocol
        if case .rclone(let cfg) = remote.backend {
            input = RawBackendInput(type: cfg.type, plainText: RawBackendInput.plainText(of: cfg),
                                    secretText: "", remotePath: cfg.remotePath)
        }
    }

    func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name required" }
        return input.validate(isEditing: existingRemoteID != nil)
    }

    func toRemoteAndSecrets(keeping existing: [RcloneSecretOption]) -> (Remote, [String: String])? {
        guard let (cfg, secrets) = try? input.makeConfig(keeping: existing) else { return nil }
        let remote = Remote(id: existingRemoteID ?? UUID(), name: name, backend: .rclone(cfg),
                            mountProtocol: mountProtocol, autoMount: autoMount, liveUpdates: liveUpdates)
        return (remote, secrets)
    }
}

struct RawBackendFormView: View {
    @Binding var draft: RawFormDraft

    var body: some View {
        Form {
            Section("Backend") {
                LabeledContent("Name") {
                    TextField("", text: $draft.name, prompt: Text("My remote")).textFieldStyle(.roundedBorder)
                }
                LabeledContent("rclone type") {
                    TextField("", text: $draft.input.type, prompt: Text("e.g. azureblob, b2, sugarsync"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Path") {
                    TextField("", text: $draft.input.remotePath, prompt: Text("optional"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Options") {
                    TextEditor(text: $draft.input.plainText)
                        .font(.system(.body, design: .monospaced))
                        .frame(height: 70)
                        .border(Color.secondary.opacity(0.3))
                }
                LabeledContent("Secret options") {
                    VStack(alignment: .leading, spacing: 2) {
                        TextEditor(text: $draft.input.secretText)
                            .font(.system(.body, design: .monospaced))
                            .frame(height: 50)
                            .border(Color.secondary.opacity(0.3))
                        Text(draft.existingRemoteID != nil
                             ? "One name = value per line. Leave empty to keep the saved secrets."
                             : "One name = value per line. Stored in the Keychain, never in a file.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Section("Mount") {
                LabeledContent("Protocol") {
                    Picker("", selection: $draft.mountProtocol) {
                        Text("WebDAV").tag(MountProtocol.webdav)
                        Text("NFS").tag(MountProtocol.nfs)
                    }
                    .pickerStyle(.segmented).labelsHidden()
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
