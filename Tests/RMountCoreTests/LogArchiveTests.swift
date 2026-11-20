import XCTest
@testable import RMountCore

final class LogArchiveTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-11-11T03:04:05Z")!
    private let id = "12345678-1234-1234-1234-123456789ABC"

    private func fixture() throws -> URL {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    func testRotatesNonEmptyLogWithUTCTimestamp() throws {
        let dir = try fixture()
        let current = dir.appendingPathComponent("\(id).log")
        try "previous mount\n".write(to: current, atomically: true, encoding: .utf8)

        LogArchive.rotate(current: current, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: current.path))
        let archive = dir.appendingPathComponent("\(id).20261111-030405.log")
        XCTAssertEqual(try String(contentsOf: archive, encoding: .utf8), "previous mount\n")
    }

    func testEmptyAndMissingLogsAreNotArchived() throws {
        let dir = try fixture()
        let current = dir.appendingPathComponent("\(id).log")
        LogArchive.rotate(current: current, now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])

        try Data().write(to: current)
        LogArchive.rotate(current: current, now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [current.lastPathComponent])
        XCTAssertEqual(try Data(contentsOf: current), Data())
    }

    func testCollisionUsesNextAvailableSuffixWithoutOverwriting() throws {
        let dir = try fixture()
        let current = dir.appendingPathComponent("\(id).log")
        let stem = "\(id).20261111-030405"
        for name in ["\(stem).log", "\(stem)-1.log"] {
            try "existing".write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        try "new".write(to: current, atomically: true, encoding: .utf8)

        LogArchive.rotate(current: current, now: now)

        for name in ["\(stem).log", "\(stem)-1.log"] {
            XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8), "existing")
        }
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("\(stem)-2.log"), encoding: .utf8), "new")
    }

    func testRetentionUsesModificationDateAndCleansOtherRemotes() throws {
        let dir = try fixture()
        let current = dir.appendingPathComponent("\(id).log")
        let cutoff = now.addingTimeInterval(-30 * 24 * 3600)
        let oldNames = ["\(id).20261111-030405.log", "\(UUID().uuidString.lowercased()).20261111-030405-2.log"]
        let keptNames = ["\(id).20200101-000000.log", "\(id).20200101-000000-1.log", current.lastPathComponent]
        for name in oldNames + keptNames {
            let file = dir.appendingPathComponent(name)
            try Data().write(to: file)
            let modified = oldNames.contains(name) || name == current.lastPathComponent
                ? cutoff.addingTimeInterval(-1) : cutoff
            try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: file.path)
        }

        LogArchive.rotate(current: current, now: now)

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), Set(keptNames))
    }

    func testCustomRetentionAndMissingCurrentStillCleanArchives() throws {
        let dir = try fixture()
        let archive = dir.appendingPathComponent("\(id).20261111-020000.log")
        try Data().write(to: archive)
        try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-3601)], ofItemAtPath: archive.path)

        LogArchive.rotate(current: dir.appendingPathComponent("\(id).log"), retention: 3600, now: now)

        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
    }

    func testUnrelatedFilesAndDirectoriesAreUntouched() throws {
        let dir = try fixture()
        let names = ["notes.log", "not-a-uuid.20261111-030405.log", "\(id).log",
                     "\(id).20261111-030405-0.log", "\(id).20261111-030405.log.bak",
                     "\(id).20261111-030405-extra.log", "\(id).2026111-030405.log",
                     "\(id).20261111-030405.log\n"]
        for name in names {
            let file = dir.appendingPathComponent(name)
            try Data().write(to: file)
            try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: file.path)
        }
        let directory = dir.appendingPathComponent("\(id).20261111-030405.log")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.modificationDate: Date.distantPast], ofItemAtPath: directory.path)

        LogArchive.rotate(current: dir.appendingPathComponent("\(id).log"), now: now)

        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: dir.path)), Set(names + [directory.lastPathComponent]))
    }

    func testMissingDirectoryIsIgnored() throws {
        let dir = try fixture()
        LogArchive.rotate(current: dir.appendingPathComponent("missing/\(id).log"), now: now)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
}
