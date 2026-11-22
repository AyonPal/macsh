import XCTest
@testable import RMountCore

final class TransferProgressTests: XCTestCase {
    func testTolerantStatsDecoding() throws {
        for json in ["{}", "{\"transferring\":null}", "{\"transferring\":false}", "{\"transferring\":[]}"] {
            XCTAssertEqual(try JSONDecoder().decode(RcloneStats.self, from: Data(json.utf8)).transferring, [])
        }
        let json = """
        {"bytes":999999,"transferring":[null,5,{"name":"a","bytes":12,"size":100,"percentage":12,"speed":4.5,"speedAvg":3,"eta":null},{"name":5,"bytes":"bad","size":null,"percentage":[],"speed":false,"speedAvg":{},"eta":"bad"}]}
        """
        let stats = try JSONDecoder().decode(RcloneStats.self, from: Data(json.utf8))
        XCTAssertEqual(stats.transferring.count, 2)
        XCTAssertEqual(stats.transferring[0], .init(name: "a", bytes: 12, size: 100, percentage: 12, speed: 4.5, speedAvg: 3))
        XCTAssertEqual(stats.transferring[1], .init())
    }

    func testStatesAndExactPathMatching() {
        let queue = VFSQueue(queue: [
            .init(name: "waiting", size: 100),
            .init(name: "a/file", size: 100, uploading: true),
            .init(name: "b/file", size: 200, uploading: true),
            .init(name: "finish", size: 10, uploading: true),
            .init(name: "retry", size: 100, uploading: true, tries: 2)
        ])
        let stats = RcloneStats(transferring: [
            .init(name: "waiting", bytes: 100),
            .init(name: "a/file", bytes: 40, speed: 10, speedAvg: 20, eta: 3),
            .init(name: "file", bytes: 200),
            .init(name: "finish", bytes: 10, percentage: 100),
            .init(name: "retry", bytes: 2),
            .init(name: "download", bytes: 1000)
        ])
        let rows = queue.status(stats: stats).transfers
        XCTAssertEqual(rows.count, 5)
        XCTAssertEqual(rows.map(\.state), [.queued, .uploading, .uploading, .finishing, .retrying])
        XCTAssertNil(rows[0].bytesDone)
        XCTAssertEqual(rows[1].bytesDone, 40)
        XCTAssertEqual(rows[1].fraction, 0.4)
        XCTAssertEqual(rows[1].speed, 20)
        XCTAssertEqual(rows[1].eta, 3)
        XCTAssertNil(rows[2].bytesDone)
        XCTAssertTrue(queue.status(stats: stats).hasPending)
        XCTAssertFalse(VFSQueue().status(stats: stats).hasPending)
    }

    func testSidecarsAndAmbiguousNames() {
        let queue = VFSQueue(queue: [
            .init(name: "dir/._side", size: 1, uploading: true),
            .init(name: "._dir/real.bin", size: 10, uploading: true),
            .init(name: "file._part", size: 10, uploading: true),
            .init(name: "same", size: 10, uploading: true)
        ])
        let stats = RcloneStats(transferring: [
            .init(name: "dir/._side", bytes: 1), .init(name: "._dir/real.bin", bytes: 3),
            .init(name: "file._part", bytes: 4), .init(name: "same", bytes: 2), .init(name: "same", bytes: 3)
        ])
        let rows = queue.status(stats: stats).transfers
        XCTAssertEqual(rows.map(\.path), ["._dir/real.bin", "file._part", "same"])
        XCTAssertEqual(rows[0].bytesDone, 3)
        XCTAssertEqual(rows[1].bytesDone, 4)
        XCTAssertNil(rows[2].bytesDone)
    }

    func testClampingUnknownFieldsAndZeroSpeed() {
        let queue = VFSQueue(queue: [
            .init(name: "negative", size: 10, uploading: true),
            .init(name: "over", size: 10, uploading: true),
            .init(name: "unknown", size: -1, uploading: true),
            .init(name: "zero", size: 0, uploading: true)
        ])
        let rows = queue.status(stats: RcloneStats(transferring: [
            .init(name: "negative", bytes: -10, speed: 0, eta: 10),
            .init(name: "over", bytes: 100, speed: -10, eta: -1),
            .init(name: "unknown", percentage: 120, speed: .infinity, eta: .infinity),
            .init(name: "zero", percentage: -10, speed: .nan, eta: .nan)
        ])).transfers
        XCTAssertEqual(rows[0].bytesDone, 0)
        XCTAssertEqual(rows[0].fraction, 0)
        XCTAssertNil(rows[0].speed)
        XCTAssertNil(rows[0].eta)
        XCTAssertEqual(rows[1].bytesDone, 10)
        XCTAssertEqual(rows[1].state, .finishing)
        XCTAssertNil(rows[2].totalBytes)
        XCTAssertEqual(rows[2].fraction, 1)
        XCTAssertNil(rows[2].speed)
        XCTAssertNil(rows[2].eta)
        XCTAssertEqual(rows[3].fraction, 0)
        let bad = VFSQueue(queue: [.init(name: "x", uploading: true)]).status(stats: .init(transferring: [.init(name: "x", percentage: .nan)]))
        XCTAssertNil(bad.transfers[0].fraction)
        let fallback = VFSQueue(queue: [.init(name: "x", uploading: true)]).status(stats: .init(transferring: [.init(name: "x", bytes: 1, size: 5, speed: 1)]))
        XCTAssertEqual(fallback.transfers[0].totalBytes, 5)
    }

    func testSummaryUsesQueueInventoryAndMeasuredRemaining() {
        let queue = VFSQueue(queue: [.init(name: "a", size: 12_000_000, uploading: true), .init(name: "b", size: 8_000_000)])
        let status = queue.status(stats: .init(transferring: [.init(name: "a", bytes: 6_000_000, speed: 120_000)]))
        XCTAssertEqual(status.summary.fileCount, 2)
        XCTAssertEqual(status.summary.bytesLeft, 14_000_000)
        XCTAssertEqual(status.summary.speed, 120_000)
        XCTAssertEqual(status.summary.eta!, 116.6666667, accuracy: 0.001)
        XCTAssertTrue(status.menuText.contains("14 MB left (about 2 min)"))
        XCTAssertTrue(queue.status.menuText.contains("20 MB)"))
        XCTAssertTrue(VFSQueue(queue: [.init(name: "x", size: 21_000_000)]).status.menuText.contains("Uploading 1 file (21 MB)"))
        XCTAssertTrue(VFSQueue(queue: [.init(name: "x")]).status.menuText.contains("size unknown"))
        XCTAssertNil(VFSQueue(queue: [.init(name: "x")]).status.summary.bytesLeft)
        XCTAssertNil(VFSQueue(queue: [.init(name: "x")]).status.summary.eta)
    }

    func testSummaryDurationAndOverflow() {
        func status(speed: Double, size: Int64 = 1000) -> UploadStatus {
            VFSQueue(queue: [.init(name: "a", size: size, uploading: true)]).status(stats: .init(transferring: [.init(name: "a", bytes: 0, speed: speed)]))
        }
        XCTAssertTrue(status(speed: 100).menuText.contains("about 10 sec"))
        XCTAssertTrue(status(speed: 0.1).menuText.contains("about 3 hr"))
        XCTAssertNil(status(speed: .leastNonzeroMagnitude).summary.eta)
        XCTAssertNil(status(speed: 0).summary.eta)
        let huge = VFSQueue(queue: [.init(size: .max), .init(size: .max)]).status
        XCTAssertEqual(huge.totalBytes, .max)
        XCTAssertEqual(huge.summary.bytesLeft, .max)
    }
}
