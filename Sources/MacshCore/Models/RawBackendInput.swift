import Foundation

/// The "Other rclone backend" escape hatch: any rclone backend type with options typed as
/// `key = value` lines. Plain options go to the temporary rclone config; secret options are
/// kept in the Keychain and reach rclone only through `RCLONE_CONFIG_R_*` environment
/// variables, like every other backend. Plain options that look like secrets are rejected so
/// a credential cannot end up in `remotes.json` or the config file by mistake.
public struct RawBackendInput: Equatable {
    public var type: String
    public var plainText: String
    public var secretText: String
    public var remotePath: String

    public init(type: String = "", plainText: String = "", secretText: String = "", remotePath: String = "") {
        self.type = type
        self.plainText = plainText
        self.secretText = secretText
        self.remotePath = remotePath
    }

    /// Option names that must go in the secret box.
    static let secretLooking = ["pass", "password", "secret", "token", "key", "credential", "private", "passphrase"]

    /// Parses `key = value` lines. Blank lines and `#` comments are skipped; the first `=`
    /// splits, so values may contain `=`. Throws a message naming the offending line.
    static func parse(_ text: String) throws -> [(key: String, value: String)] {
        var out: [(String, String)] = []
        for (i, raw) in text.split(whereSeparator: \.isNewline).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") { continue }
            guard let eq = line.firstIndex(of: "=") else { throw RawBackendError.badLine(i + 1) }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            guard !key.isEmpty, key.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == "_" }) else {
                throw RawBackendError.badKey(key)
            }
            if out.contains(where: { $0.0 == key }) { throw RawBackendError.duplicate(key) }
            out.append((key, value))
        }
        return out
    }

    /// Returns a message for the first problem, or nil.
    public func validate(isEditing: Bool) -> String? {
        let t = type.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return "Backend type required" }
        if !t.allSatisfy({ $0.isLowercase || $0.isNumber || $0 == " " || $0 == "-" }) {
            return "Backend type must be an rclone backend name, e.g. azureblob"
        }
        do {
            let plain = try Self.parse(plainText)
            let secrets = try Self.parse(secretText)
            for (k, _) in plain {
                if k == "type" { return "Set the backend in the type field, not as an option" }
                if Self.secretLooking.contains(where: { k.contains($0) }) {
                    return "Option \"\(k)\" looks like a secret: put it in the secret options"
                }
                if secrets.contains(where: { $0.key == k }) { return "Option \"\(k)\" is listed as plain and secret" }
            }
            for (k, v) in secrets {
                if k == "type" { return "Set the backend in the type field, not as an option" }
                if v.isEmpty && !isEditing { return "Secret option \"\(k)\" has no value" }
            }
        } catch {
            return (error as? RawBackendError)?.message ?? String(describing: error)
        }
        return nil
    }

    /// Config and the secret values to store. While editing, an empty secret box means
    /// "keep the saved secrets": pass `existing` so their names stay on the config.
    public func makeConfig(keeping existing: [RcloneSecretOption] = []) throws -> (RcloneBackendConfig, [String: String]) {
        let plain = try Self.parse(plainText)
        let secrets = try Self.parse(secretText)
        var secretOptions = secrets.map { RcloneSecretOption(name: $0.key, obscure: false, required: true) }
        if secrets.isEmpty { secretOptions = existing }
        var options: [String: String] = [:]
        for (k, v) in plain where !v.isEmpty { options[k] = v }
        let cfg = RcloneBackendConfig(type: type.trimmingCharacters(in: .whitespaces), options: options,
                                      secretOptions: secretOptions,
                                      remotePath: remotePath.trimmingCharacters(in: .whitespaces))
        return (cfg, Dictionary(uniqueKeysWithValues: secrets.map { ($0.key, $0.value) }))
    }

    /// Plain options of `cfg` as editable text.
    public static func plainText(of cfg: RcloneBackendConfig) -> String {
        cfg.options.keys.sorted().map { "\($0) = \(cfg.options[$0] ?? "")" }.joined(separator: "\n")
    }
}

public enum RawBackendError: Error, Equatable {
    case badLine(Int)
    case badKey(String)
    case duplicate(String)

    public var message: String {
        switch self {
        case .badLine(let n): return "Line \(n) must look like name = value"
        case .badKey(let k): return "Option name \"\(k)\" must be lowercase letters, digits and underscores"
        case .duplicate(let k): return "Option \"\(k)\" is set twice"
        }
    }
}
