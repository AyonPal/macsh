import SwiftUI
import MacshCore

enum AddBackendKind: String, CaseIterable, Identifiable {
    case sftp, s3, ftp, webdav, gdrive, smb, azure, b2, gcs, other
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sftp: return "SFTP / SSH"
        case .s3:   return "S3-compatible"
        case .ftp:  return "FTP / FTPS"
        case .webdav: return BackendDescriptor.webdav.displayName
        case .gdrive: return BackendDescriptor.googleDrive.displayName
        case .smb: return BackendDescriptor.smb.displayName
        case .azure: return BackendDescriptor.azureBlob.displayName
        case .b2: return BackendDescriptor.backblazeB2.displayName
        case .gcs: return BackendDescriptor.googleCloudStorage.displayName
        case .other: return "Other rclone backend"
        }
    }

    /// Descriptor-driven kinds (everything but SFTP/S3/FTP and the raw escape hatch).
    var descriptor: BackendDescriptor? {
        switch self {
        case .webdav: return .webdav
        case .gdrive: return .googleDrive
        case .smb: return .smb
        case .azure: return .azureBlob
        case .b2: return .backblazeB2
        case .gcs: return .googleCloudStorage
        case .sftp, .s3, .ftp, .other: return nil
        }
    }
}

/// Add/Edit window styled to match the Maccy-style Settings: flat
/// background, grouped form rows with right-aligned labels, prominent
/// primary action. Type picker locks in edit mode so secrets and
/// keychain layout don't drift.
struct AddRemoteView: View {
    let manager: SessionManager
    let prefs: UserPreferences
    let editingRemote: Remote?

    @Environment(\.dismiss) private var dismiss
    @State private var kind: AddBackendKind
    @State private var sftp: SFTPFormDraft
    @State private var s3: S3FormDraft
    @State private var ftp: FTPFormDraft
    @State private var generic: [AddBackendKind: GenericFormDraft]
    @State private var raw: RawFormDraft
    @State private var authorizer = OAuthAuthorizer()
    @State private var error: String?
    @State private var customizeTuning: Bool
    @State private var tuning: TransferTuning
    @State private var readOnly: Bool
    @State private var bandwidth: String
    @State private var testing = false
    @State private var testResult: ConnectionTestResult?

    init(manager: SessionManager, prefs: UserPreferences, editing: Remote? = nil) {
        self.manager = manager
        self.prefs = prefs
        self.editingRemote = editing

        var sftpDraft = SFTPFormDraft()
        var s3Draft = S3FormDraft()
        var ftpDraft = FTPFormDraft()
        var genericDrafts: [AddBackendKind: GenericFormDraft] = [:]
        for k in AddBackendKind.allCases {
            if let d = k.descriptor {
                var draft = GenericFormDraft(descriptor: d)
                draft.mountProtocol = prefs.defaultProtocol
                genericDrafts[k] = draft
            }
        }
        var rawDraft = RawFormDraft()
        rawDraft.mountProtocol = prefs.defaultProtocol
        sftpDraft.mountProtocol = prefs.defaultProtocol
        s3Draft.mountProtocol = prefs.defaultProtocol
        ftpDraft.mountProtocol = prefs.defaultProtocol

        var initialKind: AddBackendKind = .sftp
        if let r = editing {
            switch r.backend {
            case .sftp: initialKind = .sftp; sftpDraft = SFTPFormDraft(editing: r)
                if sftpDraft.authKind == .keyFile, let path = manager.storedKeyFilePath(for: r.id) {
                    sftpDraft.keyFilePath = path
                }
            case .s3:   initialKind = .s3;   s3Draft   = S3FormDraft(editing: r)
            case .ftp:  initialKind = .ftp;  ftpDraft  = FTPFormDraft(editing: r)
            case .rclone(let cfg):
                if let k = AddBackendKind.allCases.first(where: { $0.descriptor?.type == cfg.type }),
                   let d = k.descriptor {
                    initialKind = k
                    genericDrafts[k] = GenericFormDraft(editing: r, descriptor: d)
                } else {
                    initialKind = .other
                    rawDraft = RawFormDraft(editing: r)
                }
            }
        }
        _kind = State(initialValue: initialKind)
        let proto = editing?.mountProtocol ?? prefs.defaultProtocol
        var initialType: String? = initialKind.descriptor?.type
        if case .rclone(let cfg)? = editing?.backend { initialType = cfg.type }
        _customizeTuning = State(initialValue: editing?.tuning != nil)
        _tuning = State(initialValue: editing?.tuning ?? .defaults(for: proto, backendType: initialType))
        _readOnly = State(initialValue: editing?.readOnly ?? false)
        _bandwidth = State(initialValue: editing?.bandwidthLimit ?? "")
        _sftp = State(initialValue: sftpDraft)
        _s3 = State(initialValue: s3Draft)
        _ftp = State(initialValue: ftpDraft)
        _generic = State(initialValue: genericDrafts)
        _raw = State(initialValue: rawDraft)
    }

    private var isEditing: Bool { editingRemote != nil }

    private func genericBinding(_ k: AddBackendKind) -> Binding<GenericFormDraft> {
        Binding(get: { generic[k] ?? GenericFormDraft(descriptor: k.descriptor ?? .webdav) },
                set: { generic[k] = $0 })
    }

    /// Secret option names of the remote being edited (kept when the secret box is left empty).
    private var savedSecretOptions: [RcloneSecretOption] {
        if case .rclone(let cfg)? = editingRemote?.backend { return cfg.secretOptions }
        return []
    }

    /// rclone backend type behind the current form, used to pick cloud-friendly tuning defaults.
    private var currentBackendType: String? {
        if case .rclone(let cfg)? = editingRemote?.backend { return cfg.type }
        return kind.descriptor?.type
    }

    private var currentProtocol: MountProtocol {
        switch kind {
        case .sftp: return sftp.mountProtocol
        case .s3:   return s3.mountProtocol
        case .ftp:  return ftp.mountProtocol
        case .other: return raw.mountProtocol
        default: return generic[kind]?.mountProtocol ?? prefs.defaultProtocol
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    form
                    TuningSection(customize: $customizeTuning, tuning: $tuning, mountProtocol: currentProtocol, backendType: currentBackendType)
                    MountOptionsSection(readOnly: $readOnly, bandwidth: $bandwidth)
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(isEditing ? "Edit remote" : "Add remote")
                .font(.title3.weight(.semibold))
            Spacer()
            Picker("", selection: $kind) {
                ForEach(AddBackendKind.allCases) { k in Text(k.label).tag(k) }
            }
            .labelsHidden()
            .frame(width: 200)
            .disabled(isEditing)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var form: some View {
        switch kind {
        case .sftp: SFTPFormView(draft: $sftp)
        case .s3:   S3FormView(draft: $s3)
        case .ftp:  FTPFormView(draft: $ftp)
        case .other: RawBackendFormView(draft: $raw)
        default:
            GenericBackendFormView(draft: genericBinding(kind), prefs: prefs, authorizer: authorizer)
        }
    }

    private var footer: some View {
        HStack {
            if testing {
                ProgressView().controlSize(.small)
                Text("Testing…").font(.callout).foregroundStyle(.secondary)
            } else if let testResult {
                Label(testResult.message, systemImage: testResult.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                    .font(.callout)
                    .foregroundStyle(testResult.ok ? .green : .red)
                    .lineLimit(3)
            } else if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Test connection") { testConnection() }
                .disabled(testing)
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save changes" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    /// The form's current values as a remote plus its (unsaved) secrets, or nil after
    /// showing the first validation problem.
    private func currentRemote() -> (Remote, SessionManager.DraftSecrets)? {
        if customizeTuning, let v = tuning.validate() { error = v; return nil }
        if let v = MountOptions.validateBandwidth(bandwidth) { error = v; return nil }
        var remote: Remote
        var draft = SessionManager.DraftSecrets()
        switch kind {
        case .sftp:
            if let v = sftp.validate() { error = v; return nil }
            let (r, secrets) = sftp.toRemoteAndSecrets()
            remote = r; draft.sftp = secrets
        case .s3:
            if let v = s3.validate() { error = v; return nil }
            let (r, secrets) = s3.toRemoteAndSecrets()
            remote = r; draft.s3 = secrets
        case .ftp:
            if let v = ftp.validate() { error = v; return nil }
            let (r, secrets) = ftp.toRemoteAndSecrets()
            remote = r; draft.ftp = secrets
        case .other:
            if let v = raw.validate() { error = v; return nil }
            guard let (r, secrets) = raw.toRemoteAndSecrets(keeping: savedSecretOptions) else {
                error = "Check the option lines"; return nil
            }
            remote = r; draft.options = secrets
        default:
            guard let g = generic[kind] else { return nil }
            if let v = g.validate() { error = v; return nil }
            let (r, secrets) = g.toRemoteAndSecrets()
            remote = r; draft.options = secrets
        }
        remote.tuning = customizeTuning ? tuning : nil
        remote.readOnly = readOnly
        let bw = bandwidth.trimmingCharacters(in: .whitespaces)
        remote.bandwidthLimit = bw.isEmpty ? nil : bw
        error = nil
        return (remote, draft)
    }

    private func testConnection() {
        testResult = nil
        guard let (remote, draft) = currentRemote() else { return }
        testing = true
        Task { @MainActor in
            testResult = await manager.testConnection(remote, draft: draft)
            testing = false
        }
    }

    private func save() {
        testResult = nil
        guard let (remote, draft) = currentRemote() else { return }
        do {
            switch kind {
            case .sftp:
                if isEditing { try manager.update(remote, sftpSecrets: draft.sftp) }
                else { try manager.add(remote, sftpSecrets: draft.sftp) }
            case .s3:
                if isEditing { try manager.update(remote, s3Secrets: draft.s3) }
                else { try manager.add(remote, s3Secrets: draft.s3) }
            case .ftp:
                if isEditing { try manager.update(remote, ftpSecrets: draft.ftp) }
                else { try manager.add(remote, ftpSecrets: draft.ftp) }
            default:
                if isEditing { try manager.update(remote, optionSecrets: draft.options) }
                else { try manager.add(remote, optionSecrets: draft.options) }
            }
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
