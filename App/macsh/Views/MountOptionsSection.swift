import SwiftUI
import MacshCore

/// "Mount options" block shared by every backend form: read-only mounts and a bandwidth cap.
struct MountOptionsSection: View {
    @Binding var readOnly: Bool
    @Binding var bandwidth: String

    var body: some View {
        Form {
            Section("Mount options") {
                LabeledContent("Access") {
                    Toggle("Read-only (reject writes)", isOn: $readOnly)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                LabeledContent("Bandwidth limit") {
                    TextField("", text: $bandwidth, prompt: Text("unlimited, e.g. 10M or 10M:1M"))
                        .textFieldStyle(.roundedBorder)
                }
                Text("Limits use rclone's format: 10M for both directions, or download:upload such as 10M:1M.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
