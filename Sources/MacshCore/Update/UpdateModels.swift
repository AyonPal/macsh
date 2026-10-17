import Foundation

/// Which releases the app offers: tagged `vX.Y.Z` releases or the per-commit nightly pre-releases.
public enum UpdateChannel: String, CaseIterable, Codable {
    case stable
    case nightly

    public var displayName: String {
        switch self {
        case .stable: return "Stable releases"
        case .nightly: return "Nightly builds"
        }
    }
}

public struct ReleaseAsset: Equatable {
    public let name: String
    public let downloadURL: URL
    public let size: Int?
    /// "sha256:<hex>" as reported by GitHub, when available.
    public let digest: String?

    public init(name: String, downloadURL: URL, size: Int? = nil, digest: String? = nil) {
        self.name = name
        self.downloadURL = downloadURL
        self.size = size
        self.digest = digest
    }
}

/// A GitHub release, reduced to what the updater needs.
public struct ReleaseInfo: Equatable, Decodable {
    public let tag: String
    public let name: String
    public let prerelease: Bool
    public let draft: Bool
    public let body: String
    public let htmlURL: URL?
    public let publishedAt: Date?
    public let assets: [ReleaseAsset]

    public init(tag: String, name: String, prerelease: Bool, draft: Bool = false, body: String = "",
                htmlURL: URL? = nil, publishedAt: Date? = nil, assets: [ReleaseAsset] = []) {
        self.tag = tag
        self.name = name
        self.prerelease = prerelease
        self.draft = draft
        self.body = body
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.assets = assets
    }

    private enum CodingKeys: String, CodingKey {
        case tag = "tag_name", name, prerelease, draft, body, htmlURL = "html_url", publishedAt = "published_at", assets
    }

    private struct AssetDTO: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int?
        let digest: String?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tag = try c.decode(String.self, forKey: .tag)
        name = (try c.decodeIfPresent(String.self, forKey: .name)) ?? tag
        prerelease = (try c.decodeIfPresent(Bool.self, forKey: .prerelease)) ?? false
        draft = (try c.decodeIfPresent(Bool.self, forKey: .draft)) ?? false
        body = (try c.decodeIfPresent(String.self, forKey: .body)) ?? ""
        htmlURL = (try c.decodeIfPresent(String.self, forKey: .htmlURL)).flatMap(URL.init(string:))
        publishedAt = (try c.decodeIfPresent(String.self, forKey: .publishedAt)).flatMap {
            ISO8601DateFormatter().date(from: $0)
        }
        let dtos = (try c.decodeIfPresent([AssetDTO].self, forKey: .assets)) ?? []
        assets = dtos.compactMap { dto in
            URL(string: dto.browser_download_url).map {
                ReleaseAsset(name: dto.name, downloadURL: $0, size: dto.size, digest: dto.digest)
            }
        }
    }

    /// Release notes for the update dialog: HTML comments (the nightly markers) removed, cut to `limit`.
    public func notesExcerpt(limit: Int = 600) -> String {
        let text = body.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.count <= limit ? text : String(text.prefix(limit)) + "…"
    }

    /// "0.1.3" for "v0.1.3".
    public var version: String { tag.hasPrefix("v") ? String(tag.dropFirst()) : tag }
}

public struct AvailableUpdate: Equatable {
    public let channel: UpdateChannel
    public let release: ReleaseInfo
    public let asset: ReleaseAsset
    /// Short human label: "0.1.4" for stable, "Nightly 2026-10-16 (abc1234)" for nightly.
    public let label: String
}

public enum UpdateCheckResult: Equatable {
    case upToDate(current: String)
    case available(AvailableUpdate)
}
