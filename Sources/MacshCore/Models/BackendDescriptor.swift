import Foundation

/// One input of a generic backend form.
public struct BackendField: Equatable {
    public enum Kind: Equatable {
        case text
        case port           // 1-65535
        case url            // must be http:// or https://
        case secret         // stored in the Keychain, never in the config file
        case oauthToken     // secret obtained by signing in (`rclone authorize`), refreshed by rclone
        case choice([String])
    }

    /// rclone option name (also the Keychain item name for secrets).
    public let key: String
    public let label: String
    public let kind: Kind
    public let required: Bool
    public let defaultValue: String
    public let placeholder: String
    /// Secrets only: value must be passed to rclone obscured.
    public let obscure: Bool

    public init(
        key: String, label: String, kind: Kind = .text, required: Bool = false,
        defaultValue: String = "", placeholder: String = "", obscure: Bool = false
    ) {
        self.key = key
        self.label = label
        self.kind = kind
        self.required = required
        self.defaultValue = defaultValue
        self.placeholder = placeholder
        self.obscure = obscure
    }

    public var isSecret: Bool { kind == .secret || kind == .oauthToken }
}

/// How to sign in to an OAuth backend with `rclone authorize <backend>`.
public struct OAuthSpec: Equatable {
    public let backend: String
    /// Option holding the requested scope; passed to `rclone authorize` as `RCLONE_<BACKEND>_<SCOPE>`.
    public let scopeKey: String?
    public let clientIDKey: String?
    public let clientSecretKey: String?

    public init(backend: String, scopeKey: String? = nil, clientIDKey: String? = nil, clientSecretKey: String? = nil) {
        self.backend = backend
        self.scopeKey = scopeKey
        self.clientIDKey = clientIDKey
        self.clientSecretKey = clientSecretKey
    }
}

/// Declares an rclone backend: which fields the form shows and which of them are
/// secrets. Drives validation, `RcloneBackendConfig` creation and the generic form.
public struct BackendDescriptor: Equatable {
    /// rclone backend type, e.g. "webdav".
    public let type: String
    public let displayName: String
    public let fields: [BackendField]
    public let remotePathLabel: String
    public let remotePathPlaceholder: String
    public let defaultRemotePath: String
    /// Set for backends that sign in through the browser instead of a password.
    public let oauth: OAuthSpec?
    /// True when the backend cannot be mounted without a path (e.g. the SMB share name).
    public let remotePathRequired: Bool

    public init(
        type: String, displayName: String, fields: [BackendField],
        remotePathLabel: String = "Path", remotePathPlaceholder: String = "", defaultRemotePath: String = "",
        oauth: OAuthSpec? = nil,
        remotePathRequired: Bool = false
    ) {
        self.type = type
        self.displayName = displayName
        self.fields = fields
        self.remotePathLabel = remotePathLabel
        self.remotePathPlaceholder = remotePathPlaceholder
        self.defaultRemotePath = defaultRemotePath
        self.oauth = oauth
        self.remotePathRequired = remotePathRequired
    }

    /// Initial form values: every field's default.
    public var defaultValues: [String: String] {
        Dictionary(uniqueKeysWithValues: fields.map { ($0.key, $0.defaultValue) })
    }

    /// Returns a message for the first problem, or nil when `values` are acceptable.
    /// While editing, blank secrets mean "keep the stored one" and are not required.
    public func validate(values: [String: String], isEditing: Bool) -> String? {
        for f in fields {
            let v = (values[f.key] ?? "").trimmingCharacters(in: .whitespaces)
            if v.isEmpty {
                if f.required && !(f.isSecret && isEditing) { return "\(f.label) required" }
                continue
            }
            switch f.kind {
            case .url:
                guard let u = URL(string: v), let scheme = u.scheme?.lowercased(),
                      scheme == "http" || scheme == "https", let host = u.host, !host.isEmpty else {
                    return "\(f.label) must be an http:// or https:// URL"
                }
            case .choice(let allowed):
                if !allowed.contains(v) { return "\(f.label) must be one of: \(allowed.joined(separator: ", "))" }
            case .port:
                guard let n = Int(v), (1...65535).contains(n) else { return "\(f.label) must be 1-65535" }
            case .text, .secret, .oauthToken:
                break
            }
        }
        return nil
    }

    /// Where to learn how to create your own OAuth client, for backends where it matters.
    public var ownClientIDHelpURL: URL? {
        type == "drive" ? URL(string: "https://rclone.org/drive/#making-your-own-client-id") : nil
    }

    /// True when this backend signs in with OAuth but no client ID is set, so rclone's shared
    /// one is used. Google rate-limits that shared client heavily (cold Drive reads measured
    /// at 0.5-0.8 MB/s on a 31 MB/s link) and rclone is retiring it during 2026.
    public func usesSharedClientID(values: [String: String]) -> Bool {
        guard let key = oauth?.clientIDKey else { return false }
        return (values[key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// An OAuth token is bound to the client that issued it. When editing, changing the
    /// client ID (or its secret) without signing in again leaves a token the new client
    /// rejects. `values` holds the token only after a fresh sign-in (blank = keep saved).
    public func clientChangeNeedsSignIn(original: [String: String], values: [String: String], isEditing: Bool) -> String? {
        guard isEditing, let spec = oauth,
              let tokenKey = fields.first(where: { $0.kind == .oauthToken })?.key else { return nil }
        if !(values[tokenKey] ?? "").isEmpty { return nil }                       // signed in again
        func norm(_ v: String?) -> String { (v ?? "").trimmingCharacters(in: .whitespaces) }
        if let key = spec.clientIDKey, norm(original[key]) != norm(values[key]) {
            return "You changed the client ID: use \"Sign in again…\" so the new client can authorize this account."
        }
        if let key = spec.clientSecretKey, !norm(values[key]).isEmpty {
            return "You entered a client secret: use \"Sign in again…\" so it can authorize this account."
        }
        return nil
    }

    /// Message if a required remote path is blank.
    public func validateRemotePath(_ path: String) -> String? {
        if remotePathRequired && path.trimmingCharacters(in: .whitespaces).isEmpty { return "\(remotePathLabel) required" }
        return nil
    }

    /// Splits form values into plain options and secret option names. Empty plain
    /// values are dropped so rclone uses its own default.
    public func makeConfig(values: [String: String], remotePath: String) -> RcloneBackendConfig {
        var options: [String: String] = [:]
        var secrets: [RcloneSecretOption] = []
        for f in fields {
            if f.isSecret {
                secrets.append(RcloneSecretOption(name: f.key, obscure: f.obscure, required: f.required,
                                                  refreshable: f.kind == .oauthToken))
            } else if let v = values[f.key]?.trimmingCharacters(in: .whitespaces), !v.isEmpty {
                options[f.key] = v
            }
        }
        return RcloneBackendConfig(type: type, options: options, secretOptions: secrets, remotePath: remotePath)
    }

    /// Secret values from the form, keyed by option name (blank ones included).
    public func secretValues(from values: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for f in fields where f.isSecret { out[f.key] = values[f.key] ?? "" }
        return out
    }

    // MARK: - Registry

    /// WebDAV, Nextcloud and ownCloud. Nextcloud users should use an app password.
    public static let webdav = BackendDescriptor(
        type: "webdav",
        displayName: "WebDAV / Nextcloud",
        fields: [
            BackendField(key: "url", label: "URL", kind: .url, required: true,
                         placeholder: "https://cloud.example.com/remote.php/dav/files/USER/"),
            BackendField(key: "vendor", label: "Server", kind: .choice(["nextcloud", "owncloud", "other"]),
                         defaultValue: "nextcloud"),
            BackendField(key: "user", label: "User", required: true, placeholder: "user"),
            BackendField(key: "pass", label: "Password", kind: .secret, required: true,
                         placeholder: "app password", obscure: true),
        ],
        remotePathLabel: "Folder",
        remotePathPlaceholder: "leave empty for the root"
    )

    /// Google Drive. Signs in through the browser (`rclone authorize drive`); rclone's shared
    /// OAuth client is rate limited, so users can supply their own client ID and secret.
    public static let googleDrive = BackendDescriptor(
        type: "drive",
        displayName: "Google Drive",
        fields: [
            BackendField(key: "scope", label: "Access", kind: .choice(["drive", "drive.readonly", "drive.file"]),
                         defaultValue: "drive"),
            BackendField(key: "token", label: "Account", kind: .oauthToken, required: true),
            BackendField(key: "team_drive", label: "Shared drive ID", placeholder: "optional"),
            BackendField(key: "root_folder_id", label: "Root folder ID", placeholder: "optional"),
            BackendField(key: "client_id", label: "Client ID", placeholder: "optional, your own OAuth client"),
            BackendField(key: "client_secret", label: "Client secret", kind: .secret, placeholder: "optional"),
        ],
        remotePathLabel: "Folder",
        remotePathPlaceholder: "leave empty for My Drive root",
        oauth: OAuthSpec(backend: "drive", scopeKey: "scope", clientIDKey: "client_id", clientSecretKey: "client_secret")
    )

    /// SMB / CIFS file shares (NAS, Windows, Samba). The share name is the first path component.
    public static let smb = BackendDescriptor(
        type: "smb",
        displayName: "SMB / Windows share",
        fields: [
            BackendField(key: "host", label: "Host", required: true, placeholder: "nas.local"),
            BackendField(key: "port", label: "Port", kind: .port, defaultValue: "445"),
            BackendField(key: "user", label: "User", required: true, placeholder: "user"),
            BackendField(key: "pass", label: "Password", kind: .secret, required: true, obscure: true),
            BackendField(key: "domain", label: "Domain", placeholder: "optional, default WORKGROUP"),
        ],
        remotePathLabel: "Share",
        remotePathPlaceholder: "share or share/folder",
        remotePathRequired: true
    )

    /// Azure Blob Storage. The container is the first path component.
    public static let azureBlob = BackendDescriptor(
        type: "azureblob",
        displayName: "Azure Blob Storage",
        fields: [
            BackendField(key: "account", label: "Storage account", required: true, placeholder: "mystorageaccount"),
            BackendField(key: "key", label: "Account key", kind: .secret, required: true),
            BackendField(key: "endpoint", label: "Endpoint", kind: .url, placeholder: "optional, e.g. a local emulator"),
        ],
        remotePathLabel: "Container",
        remotePathPlaceholder: "container or container/folder",
        remotePathRequired: true
    )

    /// Backblaze B2 through its native API (the S3-compatible API is the S3 backend).
    public static let backblazeB2 = BackendDescriptor(
        type: "b2",
        displayName: "Backblaze B2",
        fields: [
            BackendField(key: "account", label: "Key ID", required: true, placeholder: "application key ID"),
            BackendField(key: "key", label: "Application key", kind: .secret, required: true),
            BackendField(key: "endpoint", label: "Endpoint", kind: .url, placeholder: "optional"),
        ],
        remotePathLabel: "Bucket",
        remotePathPlaceholder: "bucket or bucket/folder",
        remotePathRequired: true
    )

    /// Google Cloud Storage with a service-account key (the JSON file's content).
    public static let googleCloudStorage = BackendDescriptor(
        type: "google cloud storage",
        displayName: "Google Cloud Storage",
        fields: [
            BackendField(key: "service_account_credentials", label: "Service account JSON", kind: .secret,
                         required: true, placeholder: "paste the key file content"),
            BackendField(key: "project_number", label: "Project number", placeholder: "needed to list buckets"),
            BackendField(key: "endpoint", label: "Endpoint", kind: .url, placeholder: "optional"),
        ],
        remotePathLabel: "Bucket",
        remotePathPlaceholder: "bucket or bucket/folder",
        remotePathRequired: true
    )

    public static let all: [BackendDescriptor] = [.webdav, .googleDrive, .smb, .azureBlob, .backblazeB2, .googleCloudStorage]

    public static func descriptor(forType type: String) -> BackendDescriptor? {
        all.first { $0.type == type }
    }
}
