import Foundation

/// Asks GitHub which release the app should update to, for the chosen channel.
public struct UpdateChecker {
    /// Performs a request and returns the body and HTTP status. Injected so tests need no network.
    public typealias Fetch = (URLRequest) async throws -> (Data, Int)

    public static let defaultRepo = "fperdigon/macsh"

    public enum CheckError: LocalizedError, Equatable {
        case rateLimited
        case http(Int)
        case invalidResponse
        case noRelease(UpdateChannel)
        case noAsset(String)

        public var errorDescription: String? {
            switch self {
            case .rateLimited: return "GitHub is limiting requests from this network. Try again later."
            case .http(let code): return "GitHub answered with HTTP \(code)."
            case .invalidResponse: return "Unexpected response from GitHub."
            case .noRelease(let ch): return "No \(ch == .stable ? "stable release" : "nightly build") has been published yet."
            case .noAsset(let tag): return "Release \(tag) has no download for this version of macsh."
            }
        }
    }

    private let repo: String
    private let apiBase: URL
    private let fetch: Fetch

    public init(repo: String = UpdateChecker.defaultRepo,
                apiBase: URL = URL(string: "https://api.github.com")!,
                fetch: @escaping Fetch = UpdateChecker.urlSessionFetch) {
        self.repo = repo
        self.apiBase = apiBase
        self.fetch = fetch
    }

    public static let urlSessionFetch: Fetch = { request in
        let (data, response) = try await URLSession.shared.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    public func check(channel: UpdateChannel, build: BuildInfo) async throws -> UpdateCheckResult {
        switch channel {
        case .stable: return try await checkStable(build)
        case .nightly: return try await checkNightly(build)
        }
    }

    // MARK: - Channels

    private func checkStable(_ build: BuildInfo) async throws -> UpdateCheckResult {
        let data = try await get("/repos/\(repo)/releases/latest", channel: .stable)
        let release = try decode(ReleaseInfo.self, data)
        guard VersionCompare.compare(build.version, release.version) < 0 else {
            return .upToDate(current: build.version)
        }
        return .available(try makeUpdate(release, channel: .stable, label: release.version, build: build))
    }

    private func checkNightly(_ build: BuildInfo) async throws -> UpdateCheckResult {
        let data = try await get("/repos/\(repo)/releases?per_page=30", channel: .nightly)
        let releases = try decode([ReleaseInfo].self, data)
        let nightlies = releases
            .filter { !$0.draft && $0.prerelease && $0.tag.hasPrefix("nightly-") }
            .sorted { ($0.publishedAt ?? .distantPast) > ($1.publishedAt ?? .distantPast) }
        guard let newest = nightlies.first else { throw CheckError.noRelease(.nightly) }
        if !build.isDevBuild, let sha = Self.nightlySHA(of: newest), build.sha.lowercased().hasPrefix(sha) {
            return .upToDate(current: "nightly \(build.shortSHA)")
        }
        return .available(try makeUpdate(newest, channel: .nightly, label: Self.nightlyLabel(of: newest), build: build))
    }

    // MARK: - Helpers

    /// The 7-character commit suffix of a `nightly-YYYYMMDD-<sha>` tag.
    public static func nightlySHA(of release: ReleaseInfo) -> String? {
        guard release.tag.hasPrefix("nightly-"), let last = release.tag.split(separator: "-").last,
              last.count >= 7, last.allSatisfy({ $0.isHexDigit }) else { return nil }
        return String(last).lowercased()
    }

    /// "Nightly 2026-10-16 (abc1234)" from a `nightly-YYYYMMDD-<sha>` tag, because the release
    /// title is just "Nightly". Falls back to the release name for other tags.
    public static func nightlyLabel(of release: ReleaseInfo) -> String {
        let parts = release.tag.split(separator: "-")
        guard parts.count == 3, parts[0] == "nightly", parts[1].count == 8, parts[1].allSatisfy({ $0.isNumber }),
              let sha = nightlySHA(of: release) else { return release.name }
        let d = parts[1]
        return "Nightly \(d.prefix(4))-\(d.dropFirst(4).prefix(2))-\(d.suffix(2)) (\(sha.prefix(7)))"
    }

    /// The DMG for this flavor: `macsh-lite-*.dmg` for lite, `macsh-*.dmg` otherwise.
    public static func selectAsset(_ assets: [ReleaseAsset], lite: Bool) -> ReleaseAsset? {
        assets.first { asset in
            guard asset.name.hasSuffix(".dmg") else { return false }
            return lite ? asset.name.hasPrefix("macsh-lite")
                        : (asset.name.hasPrefix("macsh-") && !asset.name.hasPrefix("macsh-lite"))
        }
    }

    private func makeUpdate(_ release: ReleaseInfo, channel: UpdateChannel, label: String, build: BuildInfo) throws -> AvailableUpdate {
        guard let asset = Self.selectAsset(release.assets, lite: build.isLite) else {
            throw CheckError.noAsset(release.tag)
        }
        return AvailableUpdate(channel: channel, release: release, asset: asset, label: label)
    }

    private func get(_ path: String, channel: UpdateChannel) async throws -> Data {
        guard let url = URL(string: apiBase.absoluteString + path) else { throw CheckError.invalidResponse }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("macsh-updater", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 20
        let (data, status) = try await fetch(req)
        switch status {
        case 200: return data
        case 404: throw CheckError.noRelease(channel)
        case 403, 429: throw CheckError.rateLimited
        default: throw CheckError.http(status)
        }
    }

    private func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) } catch { throw CheckError.invalidResponse }
    }
}
