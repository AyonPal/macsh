import SwiftUI
import MacshCore

enum AddBackendKind: String, CaseIterable, Identifiable {
    case sftp, s3, ftp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .sftp: return "SFTP / SSH"
        case .s3:   return "S3-compatible"
        case .ftp:  return "FTP / FTPS"
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
    @State private var error: String?
    @State private var customizeTuning: Bool
    @State private var tuning: TransferTuning

    init(manager: SessionManager, prefs: UserPreferences, editing: Remote? = nil) {
        self.manager = manager
        self.prefs = prefs
        self.editingRemote = editing

        var sftpDraft = SFTPFormDraft()
        var s3Draft = S3FormDraft()
        var ftpDraft = FTPFormDraft()
        sftpDraft.mountProtocol = prefs.defaultProtocol
        s3Draft.mountProtocol = prefs.defaultProtocol
        ftpDraft.mountProtocol = prefs.defaultProtocol

        var initialKind: AddBackendKind = .sftp
        if let r = editing {
            switch r.backend {
            case .sftp: initialKind = .sftp; sftpDraft = SFTPFormDraft(editing: r)
            case .s3:   initialKind = .s3;   s3Draft   = S3FormDraft(editing: r)
            case .ftp:  initialKind = .ftp;  ftpDraft  = FTPFormDraft(editing: r)
            }
        }
        _kind = State(initialValue: initialKind)
        let proto = editing?.mountProtocol ?? prefs.defaultProtocol
        _customizeTuning = State(initialValue: editing?.tuning != nil)
        _tuning = State(initialValue: editing?.tuning ?? .defaults(for: proto))
        _sftp = State(initialValue: sftpDraft)
        _s3 = State(initialValue: s3Draft)
        _ftp = State(initialValue: ftpDraft)
    }

    private var isEditing: Bool { editingRemote != nil }

    private var currentProtocol: MountProtocol {
        switch kind {
        case .sftp: return sftp.mountProtocol
        case .s3:   return s3.mountProtocol
        case .ftp:  return ftp.mountProtocol
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    form
                    TuningSection(customize: $customizeTuning, tuning: $tuning, mountProtocol: currentProtocol)
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
        }
    }

    private var footer: some View {
        HStack {
            if let error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
            Spacer()
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isEditing ? "Save changes" : "Save") { save() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func save() {
        if customizeTuning, let v = tuning.validate() { error = v; return }
        let chosenTuning: TransferTuning? = customizeTuning ? tuning : nil
        do {
            switch kind {
            case .sftp:
                if let v = sftp.validate() { error = v; return }
                var (remote, secrets) = sftp.toRemoteAndSecrets()
                remote.tuning = chosenTuning
                if isEditing { try manager.update(remote, sftpSecrets: secrets) }
                else { try manager.add(remote, sftpSecrets: secrets) }
            case .s3:
                if let v = s3.validate() { error = v; return }
                var (remote, secrets) = s3.toRemoteAndSecrets()
                remote.tuning = chosenTuning
                if isEditing { try manager.update(remote, s3Secrets: secrets) }
                else { try manager.add(remote, s3Secrets: secrets) }
            case .ftp:
                if let v = ftp.validate() { error = v; return }
                var (remote, secrets) = ftp.toRemoteAndSecrets()
                remote.tuning = chosenTuning
                if isEditing { try manager.update(remote, ftpSecrets: secrets) }
                else { try manager.add(remote, ftpSecrets: secrets) }
            }
            dismiss()
        } catch {
            self.error = String(describing: error)
        }
    }
}
