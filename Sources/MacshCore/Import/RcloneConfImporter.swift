import Foundation

/// A remote converted from an rclone.conf section, ready to be added to macsh. Secrets are
/// plaintext here (revealed from rclone's obscured form) and go straight to the Keychain.
public struct ImportedRemote {
    public var remote: Remote
    public var sftp: SFTPSecrets?
    public var s3: S3Secrets?
    public var ftp: FTPSecrets?
    public var options: [String: String] = [:]
    /// Options of the section macsh does not use, so the user knows what was dropped.
    public var ignoredOptions: [String] = []

    /// SMB needs a share name, which rclone.conf does not hold (it is part of the path).
    public var needsRemotePath = false

    /// rclone.conf has no bucket, so S3 remotes need one before they can mount.
    public var needsBucket: Bool {
        if case .s3(let c) = remote.backend { return c.bucket.isEmpty }
        return false
    }

    public mutating func setSharePath(_ path: String) {
        if case .rclone(var c) = remote.backend {
            c.remotePath = path.trimmingCharacters(in: .whitespaces)
            remote.backend = .rclone(c)
            needsRemotePath = c.remotePath.isEmpty
        }
    }

    public mutating func setBucket(_ bucket: String) {
        if case .s3(var c) = remote.backend {
            c.bucket = bucket.trimmingCharacters(in: .whitespaces)
            remote.backend = .s3(c)
        }
    }
}

public enum ImportOutcome {
    case ready(ImportedRemote)
    case unsupported(String)
}

/// Converts rclone.conf sections to macsh remotes for the backends macsh supports.
public enum RcloneConfImporter {
    public static let supportedTypes = ["sftp", "s3", "ftp", "webdav", "drive", "smb"]

    public static func isSupported(type: String) -> Bool { supportedTypes.contains(type) }

    private static let knownOptions: [String: Set<String>] = [
        "sftp": ["host", "port", "user", "pass", "key_file", "key_file_pass"],
        "s3": ["provider", "region", "endpoint", "access_key_id", "secret_access_key", "env_auth"],
        "ftp": ["host", "port", "user", "pass", "tls", "explicit_tls"],
        "webdav": ["url", "vendor", "user", "pass"],
        "drive": ["scope", "client_id", "client_secret", "token", "team_drive", "root_folder_id"],
        "smb": ["host", "port", "user", "pass", "domain"],
    ]

    /// `reveal` turns an obscured rclone password into plaintext (`rclone reveal`).
    public static func convert(
        _ section: RcloneConfSection,
        defaultProtocol: MountProtocol,
        reveal: (String) throws -> String,
        home: String = NSHomeDirectory()
    ) -> ImportOutcome {
        guard isSupported(type: section.type) else {
            let t = section.type.isEmpty ? "(none)" : section.type
            return .unsupported("Type \"\(t)\" is not supported by macsh yet")
        }
        let o = section.options
        func value(_ key: String) -> String { o[key] ?? "" }
        func plain(_ obscured: String) throws -> String { obscured.isEmpty ? "" : try reveal(obscured) }

        let backend: Backend
        var imported = ImportedRemote(
            remote: Remote(id: UUID(), name: section.name, backend: .ftp(
                FTPConfig(host: "", port: 21, user: "", remotePath: "/", tlsMode: .off)),
                mountProtocol: defaultProtocol, autoMount: false))

        do {
            switch section.type {
            case "sftp":
                guard !value("host").isEmpty else { return .unsupported("The SFTP host is missing") }
                guard !value("user").isEmpty else { return .unsupported("The SFTP user is missing") }
                var keyPath = value("key_file")
                if keyPath.hasPrefix("~") { keyPath = home + keyPath.dropFirst() }
                let cfgAuth: SFTPAuthKind
                if !keyPath.isEmpty {
                    cfgAuth = .keyFile
                    let passphrase = try plain(value("key_file_pass"))
                    imported.sftp = SFTPSecrets(password: nil, privateKeyPath: keyPath,
                                                keyPassphrase: passphrase.isEmpty ? nil : passphrase)
                } else if !value("pass").isEmpty {
                    cfgAuth = .password
                    imported.sftp = SFTPSecrets(password: try plain(value("pass")), privateKeyPath: nil, keyPassphrase: nil)
                } else {
                    return .unsupported("No password or key file (probably uses ssh-agent)")
                }
                backend = .sftp(SFTPConfig(host: value("host"), port: Int(value("port")) ?? 22,
                                           user: value("user"), remotePath: "", authKind: cfgAuth))

            case "s3":
                guard !value("access_key_id").isEmpty, !value("secret_access_key").isEmpty else {
                    return .unsupported("No access key (probably uses environment or IAM credentials)")
                }
                let provider: S3Provider
                switch value("provider") {
                case "AWS": provider = .aws
                case "Cloudflare": provider = .cloudflareR2
                case "Wasabi": provider = .wasabi
                case "Minio": provider = .minio
                case "DigitalOcean": provider = .digitalOcean
                default: provider = .other
                }
                imported.s3 = S3Secrets(accessKeyID: value("access_key_id"), secretAccessKey: value("secret_access_key"))
                backend = .s3(S3Config(provider: provider, region: value("region"),
                                       endpoint: value("endpoint").isEmpty ? nil : value("endpoint"),
                                       bucket: "", prefix: ""))

            case "ftp":
                guard !value("host").isEmpty else { return .unsupported("The FTP host is missing") }
                guard !value("pass").isEmpty else { return .unsupported("No password saved for this FTP remote") }
                let tls: FTPTLSMode = value("explicit_tls") == "true" ? .explicit : (value("tls") == "true" ? .implicit : .off)
                imported.ftp = FTPSecrets(password: try plain(value("pass")))
                backend = .ftp(FTPConfig(host: value("host"), port: Int(value("port")) ?? (tls == .implicit ? 990 : 21),
                                         user: value("user").isEmpty ? "anonymous" : value("user"),
                                         remotePath: "/", tlsMode: tls))

            case "webdav":
                guard !value("url").isEmpty else { return .unsupported("The WebDAV URL is missing") }
                guard !value("user").isEmpty, !value("pass").isEmpty else {
                    return .unsupported("No user and password saved for this WebDAV remote")
                }
                let vendor = ["nextcloud", "owncloud"].contains(value("vendor")) ? value("vendor") : "other"
                let d = BackendDescriptor.webdav
                backend = .rclone(d.makeConfig(values: ["url": value("url"), "vendor": vendor, "user": value("user")],
                                               remotePath: ""))
                imported.options = ["pass": try plain(value("pass"))]

            case "drive":
                guard !value("token").isEmpty else {
                    return .unsupported("Not signed in (no token; service accounts are not supported yet)")
                }
                let allowed = ["drive", "drive.readonly", "drive.file"]
                let scope = allowed.contains(value("scope")) ? value("scope") : "drive"
                let d = BackendDescriptor.googleDrive
                backend = .rclone(d.makeConfig(
                    values: ["scope": scope, "team_drive": value("team_drive"),
                             "root_folder_id": value("root_folder_id"), "client_id": value("client_id")],
                    remotePath: ""))
                imported.options = ["token": value("token")]
                if !value("client_secret").isEmpty { imported.options["client_secret"] = value("client_secret") }

            case "smb":
                guard !value("host").isEmpty else { return .unsupported("The SMB host is missing") }
                guard !value("user").isEmpty, !value("pass").isEmpty else {
                    return .unsupported("No user and password saved for this SMB remote")
                }
                var values = ["host": value("host"), "port": value("port").isEmpty ? "445" : value("port"),
                              "user": value("user"), "domain": value("domain")]
                if Int(values["port"] ?? "") == nil { values["port"] = "445" }
                backend = .rclone(BackendDescriptor.smb.makeConfig(values: values, remotePath: ""))
                imported.options = ["pass": try plain(value("pass"))]
                imported.needsRemotePath = true

            default:
                return .unsupported("Type \"\(section.type)\" is not supported by macsh yet")
            }
        } catch {
            return .unsupported("Could not read a saved password: \((error as? LocalizedError)?.errorDescription ?? "\(error)")")
        }

        imported.remote.backend = backend
        let known = knownOptions[section.type] ?? []
        imported.ignoredOptions = o.keys.filter { !known.contains($0) }.sorted()
        return .ready(imported)
    }

    /// `name`, or `name (imported)` / `name (imported 2)`... if it is taken (case-insensitive).
    public static func uniqueName(_ name: String, existing: [String]) -> String {
        let taken = Set(existing.map { $0.lowercased() })
        if !taken.contains(name.lowercased()) { return name }
        var candidate = "\(name) (imported)"
        var n = 2
        while taken.contains(candidate.lowercased()) {
            candidate = "\(name) (imported \(n))"
            n += 1
        }
        return candidate
    }
}
