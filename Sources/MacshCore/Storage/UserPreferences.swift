import Foundation

/// Lightweight wrapper around UserDefaults for app-wide settings.
public final class UserPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static let defaultProtocolKey = "macsh.defaultProtocol"
    private static let customRclonePathKey = "macsh.customRclonePath"

    public var defaultProtocol: MountProtocol {
        get {
            if let raw = defaults.string(forKey: Self.defaultProtocolKey),
               let p = MountProtocol(rawValue: raw) {
                return p
            }
            return .webdav
        }
        set {
            defaults.set(newValue.rawValue, forKey: Self.defaultProtocolKey)
        }
    }

    /// User-supplied path to an rclone binary. When set, takes priority over the
    /// bundled binary and Homebrew fallbacks in `RcloneBinary.resolve(prefs:)`.
    public var customRclonePath: String? {
        get {
            let s = defaults.string(forKey: Self.customRclonePathKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return (s?.isEmpty == false) ? s : nil
        }
        set {
            let trimmed = newValue?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty {
                defaults.set(trimmed, forKey: Self.customRclonePathKey)
            } else {
                defaults.removeObject(forKey: Self.customRclonePathKey)
            }
        }
    }
}
