import SwiftUI
import AppKit
import MacshCore

/// Imports remotes from an existing rclone.conf: pick which ones, give S3 remotes a bucket
/// (rclone.conf has none) and macsh adds them with their secrets in the Keychain.
struct ImportRemotesView: View {
    let manager: SessionManager
    let prefs: UserPreferences

    @Environment(\.dismiss) private var dismiss
    @State private var path: String = ""
    @State private var sections: [RcloneConfSection] = []
    @State private var selected: Set<String> = []
    @State private var buckets: [String: String] = [:]
    @State private var shares: [String: String] = [:]
    @State private var message: String?
    @State private var importing = false
    @State private var summary: SessionManager.ImportSummary?

    init(manager: SessionManager, prefs: UserPreferences) {
        self.manager = manager
        self.prefs = prefs
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .frame(width: 560, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if path.isEmpty, let found = RcloneConfParser.locate() { load(found) }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Import from rclone")
                .font(.title3.weight(.semibold))
            HStack {
                Text(path.isEmpty ? "No rclone.conf found" : path)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Button("Choose file…") { choose() }
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private var content: some View {
        if let summary {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if !summary.imported.isEmpty {
                        Label("Imported: \(summary.imported.joined(separator: ", "))",
                              systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                    ForEach(summary.skipped, id: \.name) { s in
                        Label("\(s.name): \(s.reason)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    Text("Passwords are now in your Keychain. Check each remote with Edit…, then mount it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        } else if let message {
            Text(message).foregroundStyle(.secondary).padding(20)
            Spacer()
        } else {
            List(sections, id: \.name) { section in
                row(section)
            }
            .listStyle(.inset)
        }
    }

    private func row(_ section: RcloneConfSection) -> some View {
        let supported = RcloneConfImporter.isSupported(type: section.type)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Toggle(isOn: Binding(
                    get: { selected.contains(section.name) },
                    set: { on in if on { selected.insert(section.name) } else { selected.remove(section.name) } }
                )) {
                    Text(section.name)
                }
                .disabled(!supported)
                Spacer()
                Text(section.type.isEmpty ? "unknown" : section.type)
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !supported {
                Text("Not supported by macsh yet").font(.caption).foregroundStyle(.secondary)
            } else if section.type == "smb" && selected.contains(section.name) {
                TextField("", text: Binding(
                    get: { shares[section.name] ?? "" },
                    set: { shares[section.name] = $0 }
                ), prompt: Text("Share name, e.g. media or media/photos (required)"))
                    .textFieldStyle(.roundedBorder)
            } else if section.type == "s3" && selected.contains(section.name) {
                TextField("", text: Binding(
                    get: { buckets[section.name] ?? "" },
                    set: { buckets[section.name] = $0 }
                ), prompt: Text("Bucket name (required)"))
                    .textFieldStyle(.roundedBorder)
            }
        }
        .padding(.vertical, 2)
    }

    private var footer: some View {
        HStack {
            if importing { ProgressView().controlSize(.small) }
            Spacer()
            if summary != nil {
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            } else {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Import \(selected.count) remote\(selected.count == 1 ? "" : "s")") { runImport() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(selected.isEmpty || importing)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.showsHiddenFiles = true
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".config/rclone")
        if panel.runModal() == .OK, let url = panel.url { load(url.path) }
    }

    private func load(_ file: String) {
        path = file
        summary = nil
        message = nil
        sections = []
        selected = []
        guard let text = try? String(contentsOfFile: file, encoding: .utf8) else {
            message = "Could not read \(file)."
            return
        }
        if RcloneConfParser.isEncrypted(text) {
            message = "This rclone.conf is password-encrypted. Remove the encryption with `rclone config encryption remove` and try again."
            return
        }
        sections = RcloneConfParser.parse(text)
        selected = Set(sections.filter { RcloneConfImporter.isSupported(type: $0.type) && $0.type != "s3" && $0.type != "smb" }.map(\.name))
        if sections.isEmpty { message = "No remotes found in this file." }
    }

    private func runImport() {
        importing = true
        let chosen = sections.filter { selected.contains($0.name) }
        Task { @MainActor in
            summary = await manager.importRemotes(chosen, defaultProtocol: prefs.defaultProtocol, buckets: buckets,
                                                    sharePaths: shares)
            importing = false
        }
    }
}
