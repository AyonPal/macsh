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

    // MARK: cloud listing (prefetch, long cache + polling)

    func testDriveDefaultsPrefetchAndPoll() {
        let t = TransferTuning.defaults(for: .nfs, backendType: "drive")
        XCTAssertTrue(t.prefetchFolders)
        XCTAssertEqual(t.dirCacheTime, "1h")
        XCTAssertEqual(t.pollInterval, "30s")
        XCTAssertFalse(t.acknowledgeAbuse, "abuse acknowledgement must stay opt-in")
        XCTAssertNil(t.validate())
    }

    func testNonPollingBackendsKeepTheShortCache() {
        for type in [nil, "sftp", "s3", "webdav", "smb", "azureblob"] as [String?] {
            let t = TransferTuning.defaults(for: .nfs, backendType: type)
            XCTAssertEqual(t.dirCacheTime, "10s", "\(type ?? "nil")")
            XCTAssertFalse(t.prefetchFolders)
            XCTAssertEqual(t.pollInterval, "")
        }
    }

    func testDriveServeArgs() {
        let args = TransferTuning.defaults(for: .nfs, backendType: "drive").serveArgs(liveUpdates: true)
        XCTAssertTrue(args.contains("--vfs-refresh"))
        XCTAssertEqual(args[(args.firstIndex(of: "--poll-interval") ?? 0) + 1], "30s")
        XCTAssertEqual(args[(args.firstIndex(of: "--dir-cache-time") ?? 0) + 1], "1h")
        XCTAssertFalse(args.contains("--drive-acknowledge-abuse"))
    }

    func testAcknowledgeAbuseOnlyWhenEnabled() {
        var t = TransferTuning.defaults(for: .nfs, backendType: "drive")
        t.acknowledgeAbuse = true
        XCTAssertTrue(t.serveArgs(liveUpdates: true).contains("--drive-acknowledge-abuse"))
    }

    func testPollIntervalMustBeShorterThanDirCacheTime() {
        var t = TransferTuning.defaults(for: .nfs, backendType: "drive")
        t.pollInterval = "2h"
        XCTAssertNotNil(t.validate())
        t.pollInterval = "1h"
        XCTAssertNotNil(t.validate(), "equal is not shorter")
        t.pollInterval = "1m"
        XCTAssertNil(t.validate())
        t.pollInterval = "soon"
        XCTAssertNotNil(t.validate())
        t.pollInterval = "0s"
        XCTAssertNotNil(t.validate())
    }

    func testOlderSavedTuningDecodesWithNewFieldsOff() throws {
        let json = #"{"cacheMode":"full","readAhead":"64M","bufferSize":"16M","cacheMaxSize":"1G","dirCacheTime":"30s","writeBack":"1s"}"#
        let t = try JSONDecoder().decode(TransferTuning.self, from: Data(json.utf8))
        XCTAssertFalse(t.prefetchFolders)
        XCTAssertEqual(t.pollInterval, "")
        XCTAssertFalse(t.acknowledgeAbuse)
    }

    func testEffectiveTuningUsesBackendTypeForRcloneRemotes() {
        let drive = Remote(
            id: UUID(), name: "d",
            backend: .rclone(RcloneBackendConfig(type: "drive", options: [:], secretOptions: [], remotePath: "")),
            mountProtocol: .nfs, autoMount: false)
        XCTAssertTrue(drive.effectiveTuning.prefetchFolders)
        let ftp = Remote(
            id: UUID(), name: "f",
            backend: .ftp(FTPConfig(host: "h", port: 21, user: "u", remotePath: "", tlsMode: .off)),
            mountProtocol: .nfs, autoMount: false)
        XCTAssertFalse(ftp.effectiveTuning.prefetchFolders)
        var custom = drive
        custom.tuning = TransferTuning(cacheMode: .minimal, readAhead: "", bufferSize: "", cacheMaxSize: "", dirCacheTime: "5s")
        XCTAssertEqual(custom.effectiveTuning.dirCacheTime, "5s", "a saved tuning always wins")
    }

    func testNFSMountsTolerateASlowServer() {
        let opts = Mounter.nfsMountOptions(port: 1234)
        XCTAssertTrue(opts.contains("timeo=600"))
        XCTAssertTrue(opts.contains("port=1234,mountport=1234"))
        XCTAssertTrue(opts.contains("noresvport"))
        XCTAssertFalse(opts.contains("timeo=30,"))
    }

    // MARK: parallel reads

    func testParallelReadsAreOptInEvenForDrive() {
        let t = TransferTuning.defaults(for: .nfs, backendType: "drive")
        XCTAssertEqual(t.readChunkStreams, 0, "measured no gain on Google Drive, so not a default")
        XCTAssertFalse(t.serveArgs(liveUpdates: true).contains("--vfs-read-chunk-streams"))
        var custom = t
        custom.readChunkStreams = 4
        custom.readChunkSize = "32M"
        let args = custom.serveArgs(liveUpdates: true)
        XCTAssertEqual(args[(args.firstIndex(of: "--vfs-read-chunk-streams") ?? 0) + 1], "4")
        XCTAssertEqual(args[(args.firstIndex(of: "--vfs-read-chunk-size") ?? 0) + 1], "32M")
    }

    func testOtherBackendsStaySingleStream() {
        let t = TransferTuning.defaults(for: .nfs, backendType: "sftp")
        XCTAssertEqual(t.readChunkStreams, 0)
        let args = t.serveArgs(liveUpdates: true)
        XCTAssertFalse(args.contains("--vfs-read-chunk-streams"))
        XCTAssertFalse(args.contains("--vfs-read-chunk-size"))
    }

    func testParallelReadValidation() {
        var t = TransferTuning.defaults(for: .nfs, backendType: "drive")
        t.readChunkStreams = 33
        XCTAssertNotNil(t.validate())
        t.readChunkStreams = -1
        XCTAssertNotNil(t.validate())
        t.readChunkStreams = 8
        t.readChunkSize = "big"
        XCTAssertNotNil(t.validate())
        t.readChunkSize = "16M"
        XCTAssertNil(t.validate())
    }

    func testTuningSavedBeforeParallelReadsDecodesAsSingleStream() throws {
        let json = #"{"cacheMode":"full","readAhead":"","bufferSize":"","cacheMaxSize":"","dirCacheTime":"10s","prefetchFolders":true}"#
        let t = try JSONDecoder().decode(TransferTuning.self, from: Data(json.utf8))
        XCTAssertEqual(t.readChunkStreams, 0)
        XCTAssertEqual(t.readChunkSize, "")
    }
}
