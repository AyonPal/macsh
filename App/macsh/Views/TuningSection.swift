import SwiftUI
import MacshCore

/// "Performance" block shared by every backend form. Unchecked = built-in defaults for
/// the selected mount protocol; checked = the user's own rclone cache/read-ahead values.
/// Laid out like the other form sections: grouped `Form`, `LabeledContent` rows,
/// full-width rounded text fields.
struct TuningSection: View {
    @Binding var customize: Bool
    @Binding var tuning: TransferTuning
    let mountProtocol: MountProtocol

    var body: some View {
        Form {
            Section("Performance") {
                LabeledContent("Settings") {
                    Toggle("Customize performance settings", isOn: $customize)
                        .onChange(of: customize) { _, on in
                            if on { tuning = .defaults(for: mountProtocol) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if !customize {
                    Text(defaultsSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if customize {
                    LabeledContent("Cache mode") {
                        Picker("", selection: $tuning.cacheMode) {
                            ForEach(VFSCacheMode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                    textRow("Read-ahead", $tuning.readAhead, "128M")
                    textRow("Buffer size", $tuning.bufferSize, "32M")
                    textRow("Max cache size", $tuning.cacheMaxSize, "5G")
                    textRow("Dir cache time", $tuning.dirCacheTime, "10s")
                    textRow("Write-back delay", $tuning.writeBack, "1s")
                    HStack {
                        Text("Empty uses rclone's default.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Reset to defaults") { tuning = .defaults(for: mountProtocol) }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }

    private var defaultsSummary: String {
        let d = TransferTuning.defaults(for: mountProtocol)
        var s = "Defaults for \(mountProtocol == .nfs ? "NFS" : "WebDAV"): cache \(d.cacheMode.rawValue)"
        if !d.readAhead.isEmpty { s += ", read-ahead \(d.readAhead)" }
        if !d.cacheMaxSize.isEmpty { s += ", up to \(d.cacheMaxSize)" }
        return s
    }

    private func textRow(_ label: String, _ binding: Binding<String>, _ prompt: String) -> some View {
        LabeledContent(label) {
            TextField("", text: binding, prompt: Text(prompt))
                .textFieldStyle(.roundedBorder)
        }
    }
}
