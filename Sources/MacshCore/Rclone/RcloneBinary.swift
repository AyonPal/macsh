import Foundation

public enum RcloneBinaryError: Error, CustomStringConvertible {
    case notFound(searchedPaths: [String])

    public var description: String {
        switch self {
        case .notFound(let paths):
            return """
                rclone binary not found.

                Install with Homebrew:
                    brew install rclone

                Or download from https://rclone.org/downloads/
                and place the binary at one of:
                    /opt/homebrew/bin/rclone
                    /usr/local/bin/rclone

                Or set RCLONE_PATH in the environment to an explicit path.

                Searched: \(paths.joined(separator: ", "))
                """
        }
    }
}

public enum RcloneBinary {
    /// Locate the rclone binary. Lookup order:
    /// 1. `prefs.customRclonePath` (user-set in Settings).
    /// 2. `RCLONE_PATH` env var (developer override).
    /// 3. `<Bundle.main>/Contents/Resources/rclone` (production).
    /// 4. `/opt/homebrew/bin/rclone`, `/usr/local/bin/rclone` (developer fallback).
    public static func resolve(
        prefs: UserPreferences? = nil,
        bundle: Bundle = .main,
        env: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        var searched: [String] = []
        if let custom = prefs?.customRclonePath {
            searched.append(custom)
            if FileManager.default.isExecutableFile(atPath: custom) {
                return URL(fileURLWithPath: custom)
            }
        }
        if let override = env["RCLONE_PATH"] {
            searched.append(override)
            if FileManager.default.isExecutableFile(atPath: override) {
                return URL(fileURLWithPath: override)
            }
        }
        if let bundled = bundle.url(forResource: "rclone", withExtension: nil) {
            searched.append(bundled.path)
            if FileManager.default.isExecutableFile(atPath: bundled.path) {
                return bundled
            }
        }
        for fallback in ["/opt/homebrew/bin/rclone", "/usr/local/bin/rclone"] {
            searched.append(fallback)
            if FileManager.default.isExecutableFile(atPath: fallback) {
                return URL(fileURLWithPath: fallback)
            }
        }
        throw RcloneBinaryError.notFound(searchedPaths: searched)
    }
}
