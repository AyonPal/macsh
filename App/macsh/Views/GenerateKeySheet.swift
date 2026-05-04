import SwiftUI
import AppKit
import MacshCore

struct GenerateKeySheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var keyPair: GeneratedKeyPair?
    @State private var error: String?
    @State private var generating = false
    var onConfirm: (GeneratedKeyPair) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generate SSH key").font(.headline)
            Text("macsh will generate a fresh ed25519 keypair. The private half is stored in your Keychain. Copy the public half below into the server's `~/.ssh/authorized_keys`, then click Done.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let kp = keyPair {
                GroupBox("Public key (paste into server)") {
                    HStack(alignment: .top) {
                        Text(kp.publicKeyOpenSSH)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(kp.publicKeyOpenSSH, forType: .string)
                        }
                    }
                }
                Text("Fingerprint: \(kp.fingerprintSHA256)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if generating {
                ProgressView("Generating…")
            } else {
                Button("Generate") { generate() }
            }

            if let error { Text(error).foregroundStyle(.red).font(.caption) }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Done") {
                    if let kp = keyPair { onConfirm(kp) }
                    dismiss()
                }
                .disabled(keyPair == nil)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 360)
        .onAppear { if keyPair == nil { generate() } }
    }

    private func generate() {
        generating = true
        error = nil
        DispatchQueue.global().async {
            do {
                let kp = try SSHKeygen.generateEd25519()
                DispatchQueue.main.async { keyPair = kp; generating = false }
            } catch {
                DispatchQueue.main.async { self.error = String(describing: error); generating = false }
            }
        }
    }
}
