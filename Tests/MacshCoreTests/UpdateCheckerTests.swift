import XCTest
@testable import MacshCore

final class VersionAndBuildInfoTests: XCTestCase {
    func testVersionCompare() {
        XCTAssertEqual(VersionCompare.compare("0.1.2", "0.1.3"), -1)
        XCTAssertEqual(VersionCompare.compare("0.1.3", "0.1.3"), 0)
        XCTAssertEqual(VersionCompare.compare("0.2", "0.1.9"), 1)
        XCTAssertEqual(VersionCompare.compare("0.1.10", "0.1.9"), 1)
        XCTAssertEqual(VersionCompare.compare("v0.1.3", "0.1.3"), 0)
        XCTAssertEqual(VersionCompare.compare("1.0", "1.0.0"), 0)
        XCTAssertEqual(VersionCompare.compare("0.1.3-beta", "0.1.3"), 0, "suffixes are ignored")
        XCTAssertEqual(VersionCompare.compare("abc", "0"), 0)
    }

    func testBuildInfoFromBundle() {
        let full = BuildInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.3", "MacshBuildSHA": "c71ee95147098c26d5d3d1cf1ecbcf200c1100ba"],
                             bundleIdentifier: "ai.macsh")
        XCTAssertEqual(full.version, "0.1.3")
        XCTAssertEqual(full.shortSHA, "c71ee95")
        XCTAssertFalse(full.isLite)
        XCTAssertFalse(full.isDevBuild)

        let lite = BuildInfo(infoDictionary: ["CFBundleShortVersionString": "0.1.3", "MacshBuildSHA": "dev"], bundleIdentifier: "ai.macsh.lite")
        XCTAssertTrue(lite.isLite)
        XCTAssertTrue(lite.isDevBuild)

        let missing = BuildInfo(infoDictionary: nil, bundleIdentifier: nil)
        XCTAssertEqual(missing, BuildInfo(version: "0.0.0", sha: "dev", isLite: false))
        XCTAssertTrue(BuildInfo(version: "1", sha: "$(MACSH_BUILD_SHA)", isLite: false).isDevBuild, "unexpanded build setting")
        XCTAssertTrue(BuildInfo(version: "1", sha: "", isLite: false).isDevBuild)
        // The real test bundle must at least produce something usable.
        XCTAssertFalse(BuildInfo.current.version.isEmpty)
    }

    func testChannelNames() {
        XCTAssertEqual(UpdateChannel.allCases, [.stable, .nightly])
        XCTAssertEqual(UpdateChannel.stable.displayName, "Stable releases")
        XCTAssertEqual(UpdateChannel.nightly.displayName, "Nightly builds")
    }
}

final class ReleaseDecodingTests: XCTestCase {
    private let json = #"""
    {"tag_name":"v0.1.3","name":"v0.1.3","prerelease":false,"draft":false,
     "body":"<!-- nightly-sha: abc -->\n## What's new\n- thing","html_url":"https://github.com/o/r/releases/tag/v0.1.3",
     "published_at":"2026-10-16T02:12:22Z",
     "assets":[{"name":"macsh-0.1.3.dmg","browser_download_url":"https://example.com/macsh-0.1.3.dmg","size":123,"digest":"sha256:ab"},
               {"name":"bad","browser_download_url":""}]}
    """#

    func testDecodesGitHubReleaseJSON() throws {
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        XCTAssertEqual(r.tag, "v0.1.3")
        XCTAssertEqual(r.version, "0.1.3")
        XCTAssertFalse(r.prerelease)
        XCTAssertEqual(r.htmlURL?.absoluteString, "https://github.com/o/r/releases/tag/v0.1.3")
        XCTAssertNotNil(r.publishedAt)
        XCTAssertEqual(r.assets, [ReleaseAsset(name: "macsh-0.1.3.dmg", downloadURL: URL(string: "https://example.com/macsh-0.1.3.dmg")!,
                                              size: 123, digest: "sha256:ab")], "unparseable asset URLs are dropped")
    }

    func testMissingOptionalFieldsDefault() throws {
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(#"{"tag_name":"nightly-20261016-abc1234"}"#.utf8))
        XCTAssertEqual(r.name, "nightly-20261016-abc1234")
        XCTAssertEqual(r.version, "nightly-20261016-abc1234")
        XCTAssertTrue(r.assets.isEmpty)
        XCTAssertNil(r.publishedAt)
        XCTAssertEqual(r.body, "")
    }

    func testNotesExcerptStripsMarkersAndTruncates() throws {
        let r = try JSONDecoder().decode(ReleaseInfo.self, from: Data(json.utf8))
        XCTAssertEqual(r.notesExcerpt(), "## What's new\n- thing")
        let long = ReleaseInfo(tag: "v1", name: "v1", prerelease: false, body: String(repeating: "x", count: 50))
        XCTAssertEqual(long.notesExcerpt(limit: 10), String(repeating: "x", count: 10) + "…")
    }
}

final class UpdateCheckerTests: XCTestCase {
    private func asset(_ name: String) -> String {
        #"{"name":"\#(name)","browser_download_url":"https://dl.example/\#(name)","size":1}"#
    }

    private func release(_ tag: String, name: String? = nil, prerelease: Bool = false, draft: Bool = false,
                         date: String = "2026-10-16T10:00:00Z", assets: [String]? = nil) -> String {
        let sha = tag.split(separator: "-").last.map(String.init) ?? "x"
        let list = assets ?? [asset("macsh-0.1.3-\(sha).dmg"), asset("macsh-lite-0.1.3-\(sha).dmg")]
        return #"{"tag_name":"\#(tag)","name":"\#(name ?? tag)","prerelease":\#(prerelease),"draft":\#(draft),"published_at":"\#(date)","assets":[\#(list.joined(separator: ","))]}"#
    }

    /// Builds a checker whose network answers come from `routes` (path -> (status, body)).
    private func checker(_ routes: [String: (Int, String)], seen: ((URLRequest) -> Void)? = nil) -> UpdateChecker {
        UpdateChecker(repo: "o/r", apiBase: URL(string: "https://api.test")!) { req in
            seen?(req)
            let key = req.url!.absoluteString.replacingOccurrences(of: "https://api.test", with: "")
            guard let (status, body) = routes[key] else { return (Data(), 404) }
            return (Data(body.utf8), status)
        }
    }

    private let stableBuild = BuildInfo(version: "0.1.2", sha: "aaaaaaa1111111111111111111111111111111111", isLite: false)

    // MARK: stable

    func testStableOffersNewerReleaseAndPicksTheRightFlavor() async throws {
        let c = checker(["/repos/o/r/releases/latest": (200, release("v0.1.3"))])
        guard case .available(let u) = try await c.check(channel: .stable, build: stableBuild) else { return XCTFail() }
        XCTAssertEqual(u.label, "0.1.3")
        XCTAssertEqual(u.channel, .stable)
        XCTAssertEqual(u.asset.name, "macsh-0.1.3-v0.1.3.dmg")

        let lite = BuildInfo(version: "0.1.2", sha: "dev", isLite: true)
        guard case .available(let l) = try await c.check(channel: .stable, build: lite) else { return XCTFail() }
        XCTAssertEqual(l.asset.name, "macsh-lite-0.1.3-v0.1.3.dmg")
    }

    func testStableUpToDateWhenSameOrNewer() async throws {
        let c = checker(["/repos/o/r/releases/latest": (200, release("v0.1.3"))])
        for v in ["0.1.3", "0.2.0"] {
            let r = try await c.check(channel: .stable, build: BuildInfo(version: v, sha: "dev", isLite: false))
            XCTAssertEqual(r, .upToDate(current: v))
        }
    }

    func testStableRequestsCarryGitHubHeaders() async throws {
        var seen: URLRequest?
        let c = checker(["/repos/o/r/releases/latest": (200, release("v0.1.3"))]) { seen = $0 }
        _ = try await c.check(channel: .stable, build: stableBuild)
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
        XCTAssertEqual(seen?.value(forHTTPHeaderField: "User-Agent"), "macsh-updater")
    }

    // MARK: nightly

    private let listPath = "/repos/o/r/releases?per_page=30"

    private func nightlyList() -> String {
        "[" + [
            release("v0.1.3"),
            release("nightly-20261015-1111111", name: "Nightly", prerelease: true, date: "2026-10-15T10:00:00Z"),
            release("nightly-20261016-2222222", name: "Nightly", prerelease: true, date: "2026-10-16T10:00:00Z"),
            release("nightly-20261017-3333333", name: "draft", prerelease: true, draft: true, date: "2026-10-17T10:00:00Z"),
            release("v9.9.9-rc", prerelease: true, date: "2026-10-18T10:00:00Z"),
        ].joined(separator: ",") + "]"
    }

    func testNightlyLabelComesFromTagNotTitle() {
        func info(_ tag: String) -> ReleaseInfo {
            try! JSONDecoder().decode(ReleaseInfo.self, from: Data(release(tag, name: "Nightly", prerelease: true).utf8))
        }
        XCTAssertEqual(UpdateChecker.nightlyLabel(of: info("nightly-20261016-cd9a562")), "Nightly 2026-10-16 (cd9a562)")
        XCTAssertEqual(UpdateChecker.nightlyLabel(of: info("nightly-weird")), "Nightly")
    }

    func testNightlyOffersNewestNonDraftNightly() async throws {
        let c = checker([listPath: (200, nightlyList())])
        guard case .available(let u) = try await c.check(channel: .nightly, build: stableBuild) else { return XCTFail() }
        XCTAssertEqual(u.release.tag, "nightly-20261016-2222222")
        XCTAssertEqual(u.label, "Nightly 2026-10-16 (2222222)")
        XCTAssertEqual(u.asset.name, "macsh-0.1.3-2222222.dmg")
    }

    func testNightlyUpToDateWhenRunningThatCommit() async throws {
        let c = checker([listPath: (200, nightlyList())])
        let running = BuildInfo(version: "0.1.3", sha: "2222222abcdef0123456789abcdef0123456789a", isLite: false)
        let result = try await c.check(channel: .nightly, build: running)
        XCTAssertEqual(result, .upToDate(current: "nightly 2222222"))
    }

    func testNightlyDevBuildIsAlwaysOfferedTheNewest() async throws {
        let c = checker([listPath: (200, nightlyList())])
        let dev = BuildInfo(version: "0.1.3", sha: "dev", isLite: false)
        guard case .available = try await c.check(channel: .nightly, build: dev) else { return XCTFail() }
    }

    func testNightlyWithNoNightliesFails() async throws {
        let c = checker([listPath: (200, "[" + release("v0.1.3") + "]")])
        do { _ = try await c.check(channel: .nightly, build: stableBuild); XCTFail() }
        catch { XCTAssertEqual(error as? UpdateChecker.CheckError, .noRelease(.nightly)) }
    }

    func testNightlySHAParsing() {
        func sha(_ tag: String) -> String? {
            UpdateChecker.nightlySHA(of: ReleaseInfo(tag: tag, name: tag, prerelease: true))
        }
        XCTAssertEqual(sha("nightly-20261016-ABCDEF1"), "abcdef1")
        XCTAssertNil(sha("nightly-20261016-xyz"))
        XCTAssertNil(sha("nightly-20261016-abc"), "too short")
        XCTAssertNil(sha("v0.1.3"))
    }

    // MARK: errors and assets

    func testHTTPAndFormatErrors() async throws {
        func fail(_ status: Int, _ body: String = "") async -> UpdateChecker.CheckError? {
            let c = checker(["/repos/o/r/releases/latest": (status, body)])
            do { _ = try await c.check(channel: .stable, build: stableBuild); return nil }
            catch { return error as? UpdateChecker.CheckError }
        }
        let rateLimited = await fail(403)
        let tooMany = await fail(429)
        let missing = await fail(404)
        let server = await fail(500)
        let garbage = await fail(200, "not json")
        XCTAssertEqual(rateLimited, .rateLimited)
        XCTAssertEqual(tooMany, .rateLimited)
        XCTAssertEqual(missing, .noRelease(.stable))
        XCTAssertEqual(server, .http(500))
        XCTAssertEqual(garbage, .invalidResponse)
    }

    func testReleaseWithoutMatchingDMGFails() async throws {
        let c = checker(["/repos/o/r/releases/latest": (200, release("v0.1.3", assets: [asset("notes.txt"), asset("macsh-lite-0.1.3.dmg")]))])
        do { _ = try await c.check(channel: .stable, build: stableBuild); XCTFail() }
        catch { XCTAssertEqual(error as? UpdateChecker.CheckError, .noAsset("v0.1.3")) }
    }

    func testSelectAsset() {
        let assets = ["macsh-lite-0.1.3.dmg", "macsh-0.1.3.dmg", "macsh-0.1.3.zip"].map {
            ReleaseAsset(name: $0, downloadURL: URL(string: "https://x/\($0)")!)
        }
        XCTAssertEqual(UpdateChecker.selectAsset(assets, lite: false)?.name, "macsh-0.1.3.dmg")
        XCTAssertEqual(UpdateChecker.selectAsset(assets, lite: true)?.name, "macsh-lite-0.1.3.dmg")
        XCTAssertNil(UpdateChecker.selectAsset([], lite: false))
    }

    func testErrorsAreReadable() {
        for e: UpdateChecker.CheckError in [.rateLimited, .http(500), .invalidResponse, .noRelease(.stable), .noRelease(.nightly), .noAsset("v1")] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
        XCTAssertTrue(UpdateChecker.CheckError.noRelease(.nightly).errorDescription!.contains("nightly"))
    }
}

final class UpdatePreferencesTests: XCTestCase {
    private func prefs() -> UserPreferences {
        UserPreferences(defaults: UserDefaults(suiteName: "macsh.tests.\(UUID().uuidString)")!)
    }

    func testDefaults() {
        let p = prefs()
        XCTAssertEqual(p.updateChannel, .stable)
        XCTAssertTrue(p.autoCheckUpdates)
        XCTAssertNil(p.lastUpdateCheck)
        XCTAssertNil(p.skippedUpdateTag)
    }

    func testPersistence() {
        let p = prefs()
        p.updateChannel = .nightly
        p.autoCheckUpdates = false
        p.skippedUpdateTag = "nightly-1"
        let when = Date(timeIntervalSince1970: 1_000_000)
        p.lastUpdateCheck = when
        XCTAssertEqual(p.updateChannel, .nightly)
        XCTAssertFalse(p.autoCheckUpdates)
        XCTAssertEqual(p.skippedUpdateTag, "nightly-1")
        XCTAssertEqual(p.lastUpdateCheck, when)
        p.skippedUpdateTag = nil
        p.lastUpdateCheck = nil
        XCTAssertNil(p.skippedUpdateTag)
        XCTAssertNil(p.lastUpdateCheck)
    }

    func testUpdateCheckDue() {
        let p = prefs()
        let now = Date()
        XCTAssertTrue(p.updateCheckDue(now: now), "never checked")
        p.lastUpdateCheck = now.addingTimeInterval(-3600)
        XCTAssertFalse(p.updateCheckDue(now: now))
        p.lastUpdateCheck = now.addingTimeInterval(-25 * 3600)
        XCTAssertTrue(p.updateCheckDue(now: now))
        p.autoCheckUpdates = false
        XCTAssertFalse(p.updateCheckDue(now: now), "disabled")
    }
}
