import XCTest
@testable import MacshCore

final class TransferTuningTests: XCTestCase {
    func testNFSDefaultsUseReadCacheAndShortWriteBack() {
        let t = TransferTuning.defaults(for: .nfs)
        XCTAssertEqual(t.cacheMode, .full)
        XCTAssertEqual(t.readAhead, "128M")
        XCTAssertEqual(t.bufferSize, "32M")
        XCTAssertEqual(t.cacheMaxSize, "5G")
        XCTAssertEqual(t.writeBack, "1s")
        XCTAssertNil(t.validate())
    }

    func testWebDAVDefaultsKeepPreviousBehavior() {
        let args = TransferTuning.defaults(for: .webdav).serveArgs(liveUpdates: true)
        XCTAssertEqual(args, ["--vfs-cache-mode", "writes", "--dir-cache-time", "10s", "--vfs-fast-fingerprint"])
    }

    func testNFSServeArgs() {
        let args = TransferTuning.defaults(for: .nfs).serveArgs(liveUpdates: true)
        XCTAssertEqual(args, [
            "--vfs-cache-mode", "full",
            "--vfs-cache-max-size", "5G",
            "--vfs-read-ahead", "128M",
            "--buffer-size", "32M",
            "--vfs-write-back", "1s",
            "--dir-cache-time", "10s",
            "--vfs-fast-fingerprint",
        ])
    }

    func testEmptyFieldsAreOmitted() {
        let t = TransferTuning(cacheMode: .minimal, readAhead: "", bufferSize: "", cacheMaxSize: "", dirCacheTime: "")
        XCTAssertEqual(t.serveArgs(liveUpdates: true), ["--vfs-cache-mode", "minimal", "--vfs-fast-fingerprint"])
    }

    func testLiveUpdatesOffDropsDirCacheArgs() {
        let args = TransferTuning.defaults(for: .nfs).serveArgs(liveUpdates: false)
        XCTAssertFalse(args.contains("--dir-cache-time"))
        XCTAssertFalse(args.contains("--vfs-fast-fingerprint"))
    }

    func testValidSizesAndDurations() {
        var t = TransferTuning.defaults(for: .nfs)
        for v in ["", "64", "128M", "5G", "512k", "1T"] {
            t.readAhead = v
            XCTAssertNil(t.validate(), "read-ahead \(v)")
        }
        for v in ["", "10s", "5m", "500ms", "1h"] {
            t.dirCacheTime = v
            XCTAssertNil(t.validate(), "dir cache \(v)")
        }
    }

    func testInvalidValuesAreRejected() {
        var t = TransferTuning.defaults(for: .nfs)
        t.readAhead = "lots"
        XCTAssertNotNil(t.validate())
        t = .defaults(for: .nfs)
        t.cacheMaxSize = "5 GB"
        XCTAssertNotNil(t.validate())
        t = .defaults(for: .nfs)
        t.dirCacheTime = "10"
        XCTAssertNotNil(t.validate())
        t = .defaults(for: .nfs)
        t.bufferSize = "--evil"
        XCTAssertNotNil(t.validate())
    }

    func testWriteBackZeroIsRejected() {
        var t = TransferTuning.defaults(for: .nfs)
        for v in ["0", "0s", "00s", "-1s", "abc"] {
            t.writeBack = v
            XCTAssertNotNil(t.validate(), "write-back \(v)")
        }
        for v in ["", "1s", "10s", "500ms"] {
            t.writeBack = v
            XCTAssertNil(t.validate(), "write-back \(v)")
        }
    }

    func testDecodesTuningSavedWithoutWriteBack() throws {
        let json = #"{"cacheMode":"full","readAhead":"64M","bufferSize":"16M","cacheMaxSize":"1G","dirCacheTime":"30s"}"#
        let t = try JSONDecoder().decode(TransferTuning.self, from: Data(json.utf8))
        XCTAssertEqual(t.readAhead, "64M")
        XCTAssertEqual(t.writeBack, "")
    }

    func testRemoteWithoutTuningDecodesAsNil() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","name":"n","autoMount":true,
         "mountProtocol":"nfs","backend":{"ftp":{"_0":{"host":"h","port":21,"user":"u","remotePath":"","tlsMode":"off"}}}}
        """
        let r = try JSONDecoder().decode(Remote.self, from: Data(json.utf8))
        XCTAssertNil(r.tuning)
        XCTAssertTrue(r.liveUpdates)
    }

    func testRemoteTuningRoundTrip() throws {
        var t = TransferTuning.defaults(for: .nfs)
        t.readAhead = "256M"
        let r = Remote(
            id: UUID(), name: "n",
            backend: .ftp(FTPConfig(host: "h", port: 21, user: "u", remotePath: "", tlsMode: .off)),
            mountProtocol: .nfs, autoMount: false, tuning: t
        )
        let decoded = try JSONDecoder().decode(Remote.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(decoded, r)
        XCTAssertEqual(decoded.tuning?.readAhead, "256M")
    }
}
