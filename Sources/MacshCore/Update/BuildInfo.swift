import Foundation

/// Which build of macsh is running: its version, the commit it was built from and the flavor.
public struct BuildInfo: Equatable {
    public let version: String
    /// Commit SHA the app was built from ("dev" for local builds).
    public let sha: String
    /// `macsh-lite` (uses the user's own rclone) rather than the bundled-rclone `macsh`.
    public let isLite: Bool

    public init(version: String, sha: String, isLite: Bool) {
        self.version = version
        self.sha = sha
        self.isLite = isLite
    }

    /// Reads `CFBundleShortVersionString` and `MacshBuildSHA` (filled from the
    /// `MACSH_BUILD_SHA` build setting); the flavor comes from the `.lite` bundle id suffix.
    public init(infoDictionary: [String: Any]?, bundleIdentifier: String?) {
        self.version = (infoDictionary?["CFBundleShortVersionString"] as? String) ?? "0.0.0"
        self.sha = (infoDictionary?["MacshBuildSHA"] as? String) ?? "dev"
        self.isLite = bundleIdentifier?.hasSuffix(".lite") ?? false
    }

    public static var current: BuildInfo {
        BuildInfo(infoDictionary: Bundle.main.infoDictionary, bundleIdentifier: Bundle.main.bundleIdentifier)
    }

    public var shortSHA: String { String(sha.prefix(7)) }

    /// Local/unknown build: nightly checks cannot tell whether it is current.
    public var isDevBuild: Bool { sha.isEmpty || sha == "dev" || sha.hasPrefix("$(") }
}

public enum VersionCompare {
    /// Compares dotted numeric versions ("0.1.3" vs "0.2"): -1, 0 or 1. Non-numeric parts count as 0.
    public static func compare(_ a: String, _ b: String) -> Int {
        func parts(_ s: String) -> [Int] {
            let trimmed = s.hasPrefix("v") ? String(s.dropFirst()) : s
            return trimmed.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let (x, y) = (parts(a), parts(b))
        for i in 0..<max(x.count, y.count) {
            let (l, r) = (i < x.count ? x[i] : 0, i < y.count ? y[i] : 0)
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
