import SwiftUI
import MacshCore

struct S3FormDraft {
    var name: String = ""
    var provider: S3Provider = .aws
    var region: String = S3Provider.aws.defaultRegion
    var endpoint: String = ""
    var bucket: String = ""
    var prefix: String = ""
    var accessKeyID: String = ""
    var secretAccessKey: String = ""
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
        if case .s3(let cfg) = remote.backend {
            self.provider = cfg.provider
            self.region = cfg.region
            self.endpoint = cfg.endpoint ?? ""
            self.bucket = cfg.bucket
            self.prefix = cfg.prefix
        }
    }

    func validate() -> String? {
        if name.trimmingCharacters(in: .whitespaces).isEmpty { return "Name required" }
        if bucket.trimmingCharacters(in: .whitespaces).isEmpty { return "Bucket required" }
        let isEditing = existingRemoteID != nil
        if !isEditing {
            if accessKeyID.isEmpty { return "Access key ID required" }
            if secretAccessKey.isEmpty { return "Secret access key required" }
        }
        return nil
    }

    func toRemoteAndSecrets() -> (Remote, S3Secrets) {
        let remote = Remote(
            id: existingRemoteID ?? UUID(),
            name: name,
            backend: .s3(S3Config(
                provider: provider,
                region: region,
                endpoint: endpoint.isEmpty ? nil : endpoint,
                bucket: bucket,
                prefix: prefix
            )),
            mountProtocol: mountProtocol,
            autoMount: autoMount,
            liveUpdates: liveUpdates
        )
        return (remote, S3Secrets(accessKeyID: accessKeyID, secretAccessKey: secretAccessKey))
    }
}

struct S3FormView: View {
    @Binding var draft: S3FormDraft

    var body: some View {
        Form {
            Section("Identity") {
                LabeledContent("Name") {
                    TextField("", text: $draft.name, prompt: Text("My bucket"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Provider") {
                    Picker("", selection: $draft.provider) {
                        ForEach(S3Provider.allCases, id: \.self) { p in
                            Text(p.displayName).tag(p)
                        }
                    }
                    .labelsHidden()
                    .onChange(of: draft.provider) { _, p in
                        draft.region = p.defaultRegion
                        draft.endpoint = p.defaultEndpoint ?? ""
                    }
                }
            }

            Section("Endpoint") {
                LabeledContent("Region") {
                    TextField("", text: $draft.region, prompt: Text("us-east-1"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Endpoint") {
                    TextField("", text: $draft.endpoint, prompt: Text("Provider default"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Bucket") {
                    TextField("", text: $draft.bucket, prompt: Text("my-bucket"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Prefix") {
                    TextField("", text: $draft.prefix, prompt: Text("Optional"))
                        .textFieldStyle(.roundedBorder)
                }
            }

            Section("Credentials") {
                let keep = draft.existingRemoteID != nil
                LabeledContent("Access key ID") {
                    TextField("", text: $draft.accessKeyID,
                              prompt: Text(keep ? "Leave blank to keep" : "AKIA…"))
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Secret key") {
                    SecureField("", text: $draft.secretAccessKey,
                                prompt: Text(keep ? "Leave blank to keep" : ""))
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
}
