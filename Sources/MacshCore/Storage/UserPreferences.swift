import Foundation

/// Lightweight wrapper around UserDefaults for app-wide settings.
public final class UserPreferences {
    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    private static let defaultProtocolKey = "macsh.defaultProtocol"
    private static let customRclonePathKey = "macsh.customRclonePath"
    private static let updateChannelKey = "macsh.updateChannel"
    private static let autoCheckUpdatesKey = "macsh.autoCheckUpdates"
    private static let lastUpdateCheckKey = "macsh.lastUpdateCheck"
    private static let skippedUpdateTagKey = "macsh.skippedUpdateTag"

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

    /// Which releases "Check for updates" offers. Defaults to stable.
    public var updateChannel: UpdateChannel {
        get { defaults.string(forKey: Self.updateChannelKey).flatMap(UpdateChannel.init(rawValue:)) ?? .stable }
        set { defaults.set(newValue.rawValue, forKey: Self.updateChannelKey) }
    }

    /// Check for an update in the background about once a day. On by default.
    public var autoCheckUpdates: Bool {
        get { defaults.object(forKey: Self.autoCheckUpdatesKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.autoCheckUpdatesKey) }
    }

    public var lastUpdateCheck: Date? {
        get { defaults.object(forKey: Self.lastUpdateCheckKey) as? Date }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.lastUpdateCheckKey) }
            else { defaults.removeObject(forKey: Self.lastUpdateCheckKey) }
        }
    }

    /// Release tag the user chose to skip; only silent background checks honour it.
    public var skippedUpdateTag: String? {
        get { defaults.string(forKey: Self.skippedUpdateTagKey) }
        set {
            if let newValue { defaults.set(newValue, forKey: Self.skippedUpdateTagKey) }
            else { defaults.removeObject(forKey: Self.skippedUpdateTagKey) }
        }
    }

    /// True when the automatic check is enabled and the last one was over `interval` ago.
    public func updateCheckDue(now: Date = Date(), interval: TimeInterval = 24 * 3600) -> Bool {
        guard autoCheckUpdates else { return false }
        guard let last = lastUpdateCheck else { return true }
        return now.timeIntervalSince(last) >= interval
    }
}
