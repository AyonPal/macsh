import XCTest
@testable import MacshCore

final class UpdateInstallerTests: XCTestCase {
    // MARK: helpers

    /// A minimal fake bundle: <dir>/<name>/Contents/{Info.plist,MacOS/<exe>} where the exe holds `marker`.
    @discardableResult
    private func makeApp(named name: String, in dir: URL, marker: String) throws -> URL {
        let app = dir.appendingPathComponent(name)
        let macos = app.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try marker.write(to: macos.appendingPathComponent("exe"), atomically: true, encoding: .utf8)
        try "<plist/>".write(to: app.appendingPathComponent("Contents/Info.plist"), atomically: true, encoding: .utf8)
        return app
    }

    private func marker(of app: URL) throws -> String {
        try String(contentsOf: app.appendingPathComponent("Contents/MacOS/exe"), encoding: .utf8)
    }

    /// Wraps `app` in a real DMG with hdiutil, like scripts/build-release.sh does.
    private func makeDMG(containing app: URL, in dir: URL, name: String = "update.dmg") throws -> URL {
        let stage = dir.appendingPathComponent("stage-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: stage.appendingPathComponent(app.lastPathComponent))
        let dmg = dir.appendingPathComponent(name)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["create", "-volname", "macsh", "-srcfolder", stage.path, "-fs", "HFS+", "-size", "20m", "-format", "UDZO", "-ov", dmg.path]
        p.standardOutput = Pipe()
        let err = Pipe()
        p.standardError = err
        try p.run()
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("hdiutil unavailable here: \(msg)") }
        return dmg
    }

    private func tempDir() throws -> URL {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    // MARK: checksum

    func testSHA256AndVerify() throws {
        let dir = try tempDir()
        let f = dir.appendingPathComponent("f.bin")
        try Data("abc".utf8).write(to: f)
        let known = "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        XCTAssertEqual(try UpdateInstaller.sha256(of: f), known)

        XCTAssertNoThrow(try UpdateInstaller.verify(file: f, expected: "sha256:\(known)"))
        XCTAssertNoThrow(try UpdateInstaller.verify(file: f, expected: known.uppercased()))
        XCTAssertNoThrow(try UpdateInstaller.verify(file: f, expected: nil), "no digest published: skipped")
        XCTAssertNoThrow(try UpdateInstaller.verify(file: f, expected: ""))
        XCTAssertNoThrow(try UpdateInstaller.verify(file: f, expected: "md5:123"), "other algorithms are skipped")
        XCTAssertThrowsError(try UpdateInstaller.verify(file: f, expected: "sha256:deadbeef")) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .checksumMismatch)
        }
    }

    func testSHA256OfLargeFileStreams() throws {
        let dir = try tempDir()
        let f = dir.appendingPathComponent("big.bin")
        try Data(repeating: 7, count: 3 * (1 << 20) + 5).write(to: f)
        XCTAssertEqual(try UpdateInstaller.sha256(of: f).count, 64)
    }

    // MARK: replace / install

    func testReplaceAppSwapsContents() throws {
        let dir = try tempDir()
        let current = try makeApp(named: "macsh.app", in: dir, marker: "OLD")
        let staging = dir.appendingPathComponent("stage")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let new = try makeApp(named: "macsh.app", in: staging, marker: "NEW")
        try UpdateInstaller.replaceApp(at: current, with: new)
        XCTAssertEqual(try marker(of: current), "NEW")
        XCTAssertFalse(FileManager.default.fileExists(atPath: new.path), "the staged copy is consumed")
    }

    func testReplaceAppReportsFailure() throws {
        let dir = try tempDir()
        let missingNew = dir.appendingPathComponent("nope.app")
        let current = try makeApp(named: "macsh.app", in: dir, marker: "OLD")
        XCTAssertThrowsError(try UpdateInstaller.replaceApp(at: current, with: missingNew)) {
            guard case UpdateInstaller.InstallError.replaceFailed = $0 else { return XCTFail("\($0)") }
        }
        XCTAssertEqual(try marker(of: current), "OLD", "a failed update leaves the installed app alone")
    }

    func testCanReplaceChecksParentFolder() throws {
        let dir = try tempDir()
        XCTAssertTrue(UpdateInstaller.canReplace(dir.appendingPathComponent("macsh.app")))
        XCTAssertFalse(UpdateInstaller.canReplace(URL(fileURLWithPath: "/System/Applications/Calculator.app")))
    }

    func testInstallFromRealDMG() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "macsh.app", in: dir, marker: "OLD-VERSION")
        let src = try makeApp(named: "macsh.app", in: try tempDir(), marker: "NEW-VERSION")
        let dmg = try makeDMG(containing: src, in: dir)
        let digest = "sha256:" + (try UpdateInstaller.sha256(of: dmg))

        try UpdateInstaller.install(dmg: dmg, expectedDigest: digest, over: installed)

        XCTAssertEqual(try marker(of: installed), "NEW-VERSION")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix(".macsh-update-") }
        XCTAssertTrue(leftovers.isEmpty, "staging folder removed: \(leftovers)")
    }

    func testInstallRejectsBadChecksumBeforeTouchingTheApp() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "macsh.app", in: dir, marker: "OLD-VERSION")
        let src = try makeApp(named: "macsh.app", in: try tempDir(), marker: "NEW-VERSION")
        let dmg = try makeDMG(containing: src, in: dir)
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: dmg, expectedDigest: "sha256:00", over: installed)) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .checksumMismatch)
        }
        XCTAssertEqual(try marker(of: installed), "OLD-VERSION")
    }

    func testInstallWhenDMGLacksTheApp() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "macsh.app", in: dir, marker: "OLD-VERSION")
        let other = try makeApp(named: "other.app", in: try tempDir(), marker: "X")
        let dmg = try makeDMG(containing: other, in: dir)
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: dmg, expectedDigest: nil, over: installed)) {
            XCTAssertEqual($0 as? UpdateInstaller.InstallError, .appNotFound("macsh.app"))
        }
        XCTAssertEqual(try marker(of: installed), "OLD-VERSION")
    }

    func testInstallWithUnreadableDMG() throws {
        let dir = try tempDir()
        let installed = try makeApp(named: "macsh.app", in: dir, marker: "OLD-VERSION")
        let junk = dir.appendingPathComponent("junk.dmg")
        try Data("not a disk image".utf8).write(to: junk)
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: junk, expectedDigest: nil, over: installed)) {
            guard case UpdateInstaller.InstallError.mountFailed = $0 else { return XCTFail("\($0)") }
        }
    }

    func testInstallIntoReadOnlyFolderExplainsWhy() throws {
        let dir = try tempDir()
        let locked = dir.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        let installed = try makeApp(named: "macsh.app", in: locked, marker: "OLD")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let dmg = dir.appendingPathComponent("x.dmg")
        try Data("x".utf8).write(to: dmg)
        XCTAssertThrowsError(try UpdateInstaller.install(dmg: dmg, expectedDigest: nil, over: installed)) {
            guard case UpdateInstaller.InstallError.notWritable(let folder) = $0 else { return XCTFail("\($0)") }
            XCTAssertEqual(folder, locked.path)
        }
    }

    func testClearQuarantineRemovesTheFlag() throws {
        let dir = try tempDir()
        let app = try makeApp(named: "macsh.app", in: dir, marker: "X")
        let value = "0083;00000000;Safari;"
        let rc = value.withCString { setxattr(app.path, "com.apple.quarantine", $0, Int(strlen($0)), 0, 0) }
        XCTAssertEqual(rc, 0)
        UpdateInstaller.clearQuarantine(app)
        XCTAssertEqual(getxattr(app.path, "com.apple.quarantine", nil, 0, 0, 0), -1, "attribute is gone")
    }

    func testRelaunchCommandQuotesThePath() {
        let p = UpdateInstaller.relaunchProcess(appURL: URL(fileURLWithPath: "/Applications/it's here/macsh.app"))
        XCTAssertEqual(p.executableURL?.path, "/bin/sh")
        XCTAssertEqual(p.arguments, ["-c", "sleep 1; /usr/bin/open -n '/Applications/it'\\''s here/macsh.app'"])
    }

    func testErrorsAreReadable() {
        let all: [UpdateInstaller.InstallError] = [.downloadFailed(404), .checksumMismatch, .notWritable("/Applications"),
                                                   .mountFailed("x"), .appNotFound("macsh.app"), .replaceFailed("y")]
        for e in all { XCTAssertFalse((e.errorDescription ?? "").isEmpty) }
        XCTAssertTrue(UpdateInstaller.InstallError.notWritable("/Applications").errorDescription!.contains("/Applications"))
    }
}
