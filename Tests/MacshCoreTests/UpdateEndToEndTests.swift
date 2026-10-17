import XCTest
@testable import MacshCore

/// The whole update path against a local stand-in for GitHub: real HTTP requests for the release
/// JSON and the DMG, real checksum, real hdiutil mount and app swap. Skipped without python3.
final class UpdateEndToEndTests: XCTestCase {
    private static let serverScript = """
    import http.server, os, sys
    root = sys.argv[1]
    ROUTES = {"/repos/o/r/releases/latest": "latest.json", "/repos/o/r/releases": "list.json"}

    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def do_GET(self):
            base = "http://127.0.0.1:%d" % self.server.server_address[1]
            path = self.path.split("?")[0]
            if path in ROUTES:
                body = open(os.path.join(root, ROUTES[path])).read().replace("{{BASE}}", base).encode()
            elif path.startswith("/download/") and os.path.exists(os.path.join(root, os.path.basename(path))):
                body = open(os.path.join(root, os.path.basename(path)), "rb").read()
            else:
                self.send_response(404)
                self.end_headers()
                return
            self.send_response(200)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    print(srv.server_address[1], flush=True)
    srv.serve_forever()
    """

    private struct Fixture {
        let root: URL
        let base: URL
        let installed: URL
        let dmg: URL
        let dmgDigest: String
    }

    private func startServer(root: URL) throws -> URL {
        let candidates = ["/usr/bin/python3", "/usr/local/bin/python3", "/opt/homebrew/bin/python3"]
        guard let python = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("python3 not available")
        }
        let script = root.deletingLastPathComponent().appendingPathComponent("gh-stub-\(UUID().uuidString).py")
        try Self.serverScript.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [script.path, root.path]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        addTeardownBlock { p.terminate(); try? FileManager.default.removeItem(at: script) }
        let line = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let port = Int(line) else { throw XCTSkip("stub server did not start: \(line)") }
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    private func makeFixture(digestOverride: String? = nil) throws -> Fixture {
        let top = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: top) }
        let root = top.appendingPathComponent("server")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        func app(_ marker: String, in dir: URL) throws -> URL {
            let a = dir.appendingPathComponent("macsh.app")
            try FileManager.default.createDirectory(at: a.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
            try marker.write(to: a.appendingPathComponent("Contents/MacOS/exe"), atomically: true, encoding: .utf8)
            return a
        }
        let installedDir = top.appendingPathComponent("Applications")
        try FileManager.default.createDirectory(at: installedDir, withIntermediateDirectories: true)
        let installed = try app("OLD", in: installedDir)

        let srcDir = top.appendingPathComponent("src")
        try FileManager.default.createDirectory(at: srcDir, withIntermediateDirectories: true)
        let newApp = try app("NEW", in: srcDir)
        let dmg = root.appendingPathComponent("macsh-0.1.4.dmg")
        let h = Process()
        h.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        h.arguments = ["create", "-volname", "macsh", "-srcfolder", srcDir.path, "-fs", "HFS+", "-size", "20m", "-format", "UDZO", "-ov", dmg.path]
        h.standardOutput = Pipe(); h.standardError = Pipe()
        try h.run(); h.waitUntilExit()
        guard h.terminationStatus == 0 else { throw XCTSkip("hdiutil unavailable") }
        _ = newApp

        let realDigest = "sha256:" + (try UpdateInstaller.sha256(of: dmg))
        let digest = digestOverride ?? realDigest
        func release(_ tag: String, name: String, prerelease: Bool, date: String) -> String {
            #"{"tag_name":"\#(tag)","name":"\#(name)","prerelease":\#(prerelease),"draft":false,"published_at":"\#(date)","body":"notes","html_url":"{{BASE}}/r/\#(tag)","assets":[{"name":"macsh-0.1.4.dmg","browser_download_url":"{{BASE}}/download/macsh-0.1.4.dmg","size":1,"digest":"\#(digest)"}]}"#
        }
        try release("v0.1.4", name: "v0.1.4", prerelease: false, date: "2026-10-16T10:00:00Z")
            .write(to: root.appendingPathComponent("latest.json"), atomically: true, encoding: .utf8)
        let list = "[" + [release("nightly-20261016-abcdef1", name: "Nightly 2026-10-16 (abcdef1)", prerelease: true, date: "2026-10-16T10:00:00Z"),
                          release("v0.1.4", name: "v0.1.4", prerelease: false, date: "2026-10-15T10:00:00Z")].joined(separator: ",") + "]"
        try list.write(to: root.appendingPathComponent("list.json"), atomically: true, encoding: .utf8)

        let base = try startServer(root: root)
        return Fixture(root: root, base: base, installed: installed, dmg: dmg, dmgDigest: digest)
    }

    private func marker(_ app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/MacOS/exe"), encoding: .utf8)
    }

    func testStableUpdateDownloadsVerifiesAndInstalls() async throws {
        let f = try makeFixture()
        let checker = UpdateChecker(repo: "o/r", apiBase: f.base)
        let build = BuildInfo(version: "0.1.3", sha: "dev", isLite: false)

        guard case .available(let update) = try await checker.check(channel: .stable, build: build) else { return XCTFail("no update") }
        XCTAssertEqual(update.label, "0.1.4")
        XCTAssertEqual(update.asset.digest, f.dmgDigest)

        let work = f.root.deletingLastPathComponent().appendingPathComponent("download")
        let file = try await UpdateInstaller.download(update.asset, to: work)
        XCTAssertEqual(file.lastPathComponent, "macsh-0.1.4.dmg")

        try UpdateInstaller.install(dmg: file, expectedDigest: update.asset.digest, over: f.installed)
        XCTAssertEqual(try marker(f.installed), "NEW")
    }

    func testTamperedDownloadIsRefusedAndTheInstalledAppSurvives() async throws {
        let f = try makeFixture(digestOverride: "sha256:" + String(repeating: "0", count: 64))
        let checker = UpdateChecker(repo: "o/r", apiBase: f.base)
        guard case .available(let update) = try await checker.check(channel: .stable, build: BuildInfo(version: "0.1.3", sha: "dev", isLite: false)) else {
            return XCTFail("no update")
        }
        let file = try await UpdateInstaller.download(update.asset, to: f.root.deletingLastPathComponent().appendingPathComponent("download"))
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: file, expectedDigest: update.asset.digest, over: f.installed)) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .checksumMismatch)
        }
        XCTAssertEqual(try marker(f.installed), "OLD")
    }

    func testNightlyChannelPicksTheNightlyAndRespectsTheRunningCommit() async throws {
        let f = try makeFixture()
        let checker = UpdateChecker(repo: "o/r", apiBase: f.base)

        let old = BuildInfo(version: "0.1.3", sha: "1234567aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", isLite: false)
        guard case .available(let update) = try await checker.check(channel: .nightly, build: old) else { return XCTFail("no update") }
        XCTAssertEqual(update.release.tag, "nightly-20261016-abcdef1")

        let current = BuildInfo(version: "0.1.3", sha: "abcdef1fffffffffffffffffffffffffffffffff", isLite: false)
        let result = try await checker.check(channel: .nightly, build: current)
        XCTAssertEqual(result, .upToDate(current: "nightly abcdef1"))
    }

    func testMissingDownloadIsReported() async throws {
        let f = try makeFixture()
        let missing = ReleaseAsset(name: "gone.dmg", downloadURL: f.base.appendingPathComponent("download/gone.dmg"))
        do {
            _ = try await UpdateInstaller.download(missing, to: f.root.deletingLastPathComponent().appendingPathComponent("d2"))
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(error as? UpdateInstaller.InstallError, .downloadFailed(404))
        }
    }
}
