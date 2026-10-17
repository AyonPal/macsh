import Foundation

/// A secret rclone option of a generic backend. The value lives in the Keychain and
/// reaches rclone through `RCLONE_CONFIG_R_<NAME>`; the on-disk config never has it.
public struct RcloneSecretOption: Codable, Equatable {
    public var name: String
    /// rclone expects the value in its obscured form (`rclone obscure`), like passwords.
    public var obscure: Bool
    /// When false, a missing value is skipped instead of failing the mount (e.g. an
    /// optional OAuth client secret).
    public var required: Bool
    /// rclone may rewrite this option while running (OAuth tokens refresh); macsh reads it
    /// back from rclone's config when the mount ends and updates the Keychain.
    public var refreshable: Bool

    public init(name: String, obscure: Bool, required: Bool = true, refreshable: Bool = false) {
        self.name = name
        self.obscure = obscure
        self.required = required
        self.refreshable = refreshable
    }

    private enum CodingKeys: String, CodingKey { case name, obscure, required, refreshable }

    /// Tolerant: remotes saved before `required`/`refreshable` existed still decode.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        obscure = try c.decodeIfPresent(Bool.self, forKey: .obscure) ?? false
        required = try c.decodeIfPresent(Bool.self, forKey: .required) ?? true
        refreshable = try c.decodeIfPresent(Bool.self, forKey: .refreshable) ?? false
    }
}

/// Generic rclone backend: a backend `type`, its plain options and the names of its
/// secret options. New backends are declared as data (`BackendDescriptor`) rather than
/// by adding another case and `switch` arms throughout the app.
public struct RcloneBackendConfig: Codable, Equatable {
    /// rclone backend type, e.g. "webdav".
    public var type: String
    /// Non-secret options written to the temporary rclone config.
    public var options: [String: String]
    public var secretOptions: [RcloneSecretOption]
    /// Path inside the remote handed to `rclone serve` (`r:<remotePath>`). May be empty.
    public var remotePath: String

    public init(type: String, options: [String: String], secretOptions: [RcloneSecretOption], remotePath: String) {
        self.type = type
        self.options = options
        self.secretOptions = secretOptions
        self.remotePath = remotePath
    }
}
