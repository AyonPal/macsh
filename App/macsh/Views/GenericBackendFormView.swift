import SwiftUI
import MacshCore

/// Form state for any backend declared as a `BackendDescriptor` (WebDAV, ...).
struct GenericFormDraft {
    var descriptor: BackendDescriptor
    var name: String = ""
    var values: [String: String]
    var remotePath: String
    var autoMount: Bool = true
    var liveUpdates: Bool = true
    var mountProtocol: MountProtocol = .webdav
    var existingRemoteID: UUID? = nil
    /// Plain option values when the form was opened, to notice a changed OAuth client.
    private var originalValues: [String: String] = [:]

    init(descriptor: BackendDescriptor) {
        self.descriptor = descriptor
        self.values = descriptor.defaultValues
        self.remotePath = descriptor.defaultRemotePath
    }

    init(editing remote: Remote, descriptor: BackendDescriptor) {
        self.init(descriptor: descriptor)
        self.existingRemoteID = remote.id
        self.name = remote.name
        self.autoMount = remote.autoMount
        self.liveUpdates = remote.liveUpdates
        self.mountProtocol = remote.mountProtocol
        if case .rclone(let cfg) = remote.backend {
            for (k, v) in cfg.options { values[k] = v }
            remotePath = cfg.remotePath
        }
        originalValues = values
    }

    func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name required" }
        if let v = descriptor.validate(values: values, isEditing: existingRemoteID != nil) { return v }
        if let v = descriptor.clientChangeNeedsSignIn(original: originalValues, values: values,
                                                      isEditing: existingRemoteID != nil) { return v }
        return descriptor.validateRemotePath(remotePath)
    }

    func toRemoteAndSecrets() -> (Remote, [String: String]) {
        let remote = Remote(
            id: existingRemoteID ?? UUID(),
            name: name,
            backend: .rclone(descriptor.makeConfig(
                values: values,
                remotePath: remotePath.trimmingCharacters(in: .whitespaces))),
            mountProtocol: mountProtocol,
            autoMount: autoMount,
            liveUpdates: liveUpdates
        )
        return (remote, descriptor.secretValues(from: values))
    }
}

struct GenericBackendFormView: View {
    @Binding var draft: GenericFormDraft
    /// Used by OAuth backends (Google Drive) to run `rclone authorize`.
    let prefs: UserPreferences
    let authorizer: OAuthAuthorizer

    @State private var signingIn = false
    @State private var signInError: String?

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { draft.values[key] ?? "" }, set: { draft.values[key] = $0 })
    }

    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Name") {
                    TextField("", text: $draft.name, prompt: Text("My \(draft.descriptor.displayName)"))
                        .textFieldStyle(.roundedBorder)
                }
                ForEach(draft.descriptor.fields, id: \.key) { field in
                    LabeledContent(field.label) { fieldControl(field) }
                    // Its own row, so the Client ID field keeps the standard row layout.
                    if field.key == draft.descriptor.oauth?.clientIDKey,
                       draft.descriptor.usesSharedClientID(values: draft.values) {
                        sharedClientNote
                    }
                }
                LabeledContent(draft.descriptor.remotePathLabel) {
                    TextField("", text: $draft.remotePath,
                              prompt: Text(draft.descriptor.remotePathPlaceholder))
                        .textFieldStyle(.roundedBorder)
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

    @ViewBuilder
    private func fieldControl(_ field: BackendField) -> some View {
        switch field.kind {
        case .secret:
            SecureField("", text: binding(field.key),
                        prompt: Text(draft.existingRemoteID != nil ? "Leave blank to keep" : field.placeholder))
                .textFieldStyle(.roundedBorder)
        case .choice(let options):
            Picker("", selection: binding(field.key)) {
                ForEach(options, id: \.self) { Text($0.capitalized).tag($0) }
            }
            .labelsHidden()
        case .oauthToken:
            oauthControl(field)
        case .text, .url, .port:
            TextField("", text: binding(field.key), prompt: Text(field.placeholder))
                .textFieldStyle(.roundedBorder)
        }
    }

    /// Shown under an empty Client ID: the shared one is slow and going away.
    private var sharedClientNote: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Empty uses rclone's shared client ID: heavily rate limited (slow downloads) and being retired by Google/rclone in 2026. Use your own for speed and reliability.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let url = draft.descriptor.ownClientIDHelpURL {
                Link("How to create your own client ID", destination: url).font(.caption)
            }
            if draft.existingRemoteID != nil {
                Text("After entering it, press \"Sign in again…\" below.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func oauthControl(_ field: BackendField) -> some View {
        let hasNew = !(draft.values[field.key] ?? "").isEmpty
        let hasSaved = draft.existingRemoteID != nil
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                if signingIn {
                    ProgressView().controlSize(.small)
                    Text("Finish signing in in your browser…").foregroundStyle(.secondary)
                    Button("Cancel") { authorizer.cancel() }
                } else {
                    Button(hasNew || hasSaved ? "Sign in again…" : "Sign in…") { signIn(field) }
                    if hasNew {
                        Label("Signed in", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else if hasSaved {
                        Text("Using saved sign-in").foregroundStyle(.secondary)
                    }
                }
            }
            if let signInError {
                Text(signInError).font(.callout).foregroundStyle(.red).lineLimit(3)
            }
        }
    }

    private func signIn(_ field: BackendField) {
        guard let spec = draft.descriptor.oauth else { return }
        signInError = nil
        signingIn = true
        let values = draft.values
        Task { @MainActor in
            do {
                let binary = try RcloneBinary.resolve(prefs: prefs)
                let token = try await authorizer.authorize(
                    binary: binary, backend: spec.backend,
                    clientID: spec.clientIDKey.flatMap { values[$0] },
                    clientSecret: spec.clientSecretKey.flatMap { values[$0] },
                    scope: spec.scopeKey.flatMap { values[$0] })
                draft.values[field.key] = token
            } catch OAuthError.cancelled {
                // user cancelled; nothing to report
            } catch {
                signInError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            }
            signingIn = false
        }
    }
}
