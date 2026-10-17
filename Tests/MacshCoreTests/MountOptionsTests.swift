import XCTest
@testable import MacshCore

final class MountOptionsTests: XCTestCase {
    func testBandwidthAcceptsRcloneFormats() {
        for ok in ["", "  ", "1M", "512k", "0.5M", "10", "1G", "10M:1M", "512k:0", "2.5M:100k"] {
            XCTAssertNil(MountOptions.validateBandwidth(ok), ok)
        }
    }

    func testBandwidthRejectsGarbage() {
        for bad in ["fast", "10MB", "M", "10M:", ":1M", "10M:1M:2M", "-5M", "1 M", "10Mbit"] {
            XCTAssertNotNil(MountOptions.validateBandwidth(bad), bad)
        }
    }

    func testServeArgs() {
        XCTAssertEqual(MountOptions.serveArgs(readOnly: false, bandwidthLimit: nil), [])
        XCTAssertEqual(MountOptions.serveArgs(readOnly: false, bandwidthLimit: "  "), [])
        XCTAssertEqual(MountOptions.serveArgs(readOnly: true, bandwidthLimit: nil), ["--read-only"])
        XCTAssertEqual(MountOptions.serveArgs(readOnly: true, bandwidthLimit: " 10M:1M "),
                       ["--read-only", "--bwlimit", "10M:1M"])
        XCTAssertEqual(MountOptions.serveArgs(readOnly: false, bandwidthLimit: "2M"), ["--bwlimit", "2M"])
    }

    func testRemoteDefaultsAndRoundTrip() throws {
        let plain = makeRemote(backend: ftpBackend())
        XCTAssertFalse(plain.readOnly)
        XCTAssertNil(plain.bandwidthLimit)

        var r = makeRemote(backend: ftpBackend())
        r.readOnly = true
        r.bandwidthLimit = "5M"
        let back = try JSONDecoder().decode(Remote.self, from: JSONEncoder().encode(r))
        XCTAssertEqual(back, r)
        XCTAssertTrue(back.readOnly)
        XCTAssertEqual(back.bandwidthLimit, "5M")
    }

    func testRemotesSavedBeforeTheseOptionsStillDecode() throws {
        let id = UUID()
        let legacy = """
        {"id":"\(id.uuidString)","name":"old","autoMount":true,"mountProtocol":"webdav",
         "backend":{"ftp":{"_0":{"host":"h","port":21,"user":"u","remotePath":"/","tlsMode":"off"}}}}
        """
        let r = try JSONDecoder().decode(Remote.self, from: Data(legacy.utf8))
        XCTAssertEqual(r.id, id)
        XCTAssertFalse(r.readOnly)
        XCTAssertNil(r.bandwidthLimit)
    }

    func testConfigErrorsAreReadable() {
        XCTAssertEqual(RcloneConfigError.missingSecret("pass").errorDescription,
                       "The saved value for \"pass\" is missing (sign in or enter it again).")
        for e: RcloneConfigError in [.keyFileAuthRequiresPath, .passwordAuthRequiresPassword,
                                     .missingS3Credentials, .missingFTPPassword] {
            XCTAssertFalse((e.errorDescription ?? "").isEmpty)
        }
    }
}
