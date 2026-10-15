import XCTest
@testable import MacshCore

final class MounterMountpointTests: XCTestCase {
    private var base: URL!

    override func setUpWithError() throws {
        base = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-mp-test-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: base)
    }

    func testCreatesDirectoryUnderBaseNotVolumes() throws {
        let mp = try Mounter(mountBase: base).resolveMountpoint(name: "DevEnv")
        XCTAssertEqual(mp, base.appendingPathComponent("DevEnv").path)
        XCTAssertFalse(mp.hasPrefix("/Volumes"))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: mp, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testReusesEmptyLeftoverDirectory() throws {
        let m = Mounter(mountBase: base)
        let first = try m.resolveMountpoint(name: "DevEnv")
        let second = try m.resolveMountpoint(name: "DevEnv")
        XCTAssertEqual(first, second)
    }

    func testSuffixesWhenDirectoryHasContent() throws {
        let m = Mounter(mountBase: base)
        let first = try m.resolveMountpoint(name: "DevEnv")
        try "x".write(toFile: first + "/file.txt", atomically: true, encoding: .utf8)
        let second = try m.resolveMountpoint(name: "DevEnv")
        XCTAssertEqual(second, base.appendingPathComponent("DevEnv-2").path)
    }

    func testCreatesMissingBaseDirectory() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
        _ = try Mounter(mountBase: base).resolveMountpoint(name: "x")
        XCTAssertTrue(FileManager.default.fileExists(atPath: base.path))
    }
}
