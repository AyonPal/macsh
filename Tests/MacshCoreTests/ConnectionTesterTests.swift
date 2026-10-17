import XCTest
@testable import MacshCore

final class ConnectionTesterExplainTests: XCTestCase {
    private func explain(_ s: String) -> String { ConnectionTester.explain(stderr: s) }

    func testAuthenticationFailuresFromEachProtocol() {
        let samples = [
            "Failed to create file system for \"r:\": couldn't connect SSH: ssh: handshake failed: ssh: unable to authenticate, attempted methods [none password], no supported methods remain",
            "Failed to create file system: couldn't connect: 530 Login incorrect.",
            "NOTICE: s3: InvalidAccessKeyId: The AWS Access Key Id you provided does not exist",
            "SignatureDoesNotMatch: The request signature we calculated does not match",
            "error listing: 401 Unauthorized",
            "oauth2: cannot fetch token: invalid_grant",
            "smb: failed to connect: NT Status Error: STATUS_LOGON_FAILURE",
            // Verbatim from rclone against Samba (CI) after a wrong password:
            "ERROR : error listing: couldn't connect SMB: response error: The attempted logon is invalid. This is either due to a bad username or authentication information.",
        ]
        for s in samples {
            XCTAssertTrue(explain(s).hasPrefix("Authentication failed"), s)
        }
    }

    func testUnreachableServer() {
        for s in ["dial tcp 127.0.0.1:2: connect: connection refused",
                  "dial tcp: lookup nope.invalid: no such host",
                  "read tcp 10.0.0.1:50000: i/o timeout"] {
            XCTAssertTrue(explain(s).hasPrefix("Could not reach the server"), s)
        }
    }

    func testMissingFolderAndCertificate() {
        XCTAssertTrue(explain("directory not found").hasPrefix("Folder or bucket not found"))
        XCTAssertTrue(explain("tree connect failed: STATUS_BAD_NETWORK_NAME").hasPrefix("Folder or bucket not found"))
        XCTAssertTrue(explain("NoSuchBucket: The specified bucket does not exist").hasPrefix("Folder or bucket not found"))
        XCTAssertTrue(explain("tls: failed to verify certificate: x509: certificate signed by unknown authority").hasPrefix("TLS certificate"))
    }

    func testUnknownErrorsShowTheLastLines() {
        let msg = explain("line one\nline two\nweird failure\n\n")
        XCTAssertEqual(msg, "The connection test failed:\nline two\nweird failure")
        XCTAssertEqual(explain(""), "The connection test failed.")
    }
}

final class ConnectionTesterRunTests: XCTestCase {
    private func make() throws -> (FakeRclone, URL) {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (try FakeRclone.make(in: dir), dir)
    }

    func testSuccessCountsItemsAndPassesArguments() throws {
        let (rclone, _) = try make()
        let r = ConnectionTester.run(binary: rclone.binary, configText: "[r]\ntype = ftp\n", remotePath: "/pub",
                                     env: ["RCLONE_CONFIG_R_PASS": "OBS"])
        XCTAssertEqual(r, .success("Connected — 2 items found"))
        let lines = rclone.recordedLines()
        XCTAssertEqual(Array(lines.prefix(2)), ["lsf", "r:/pub"])
        XCTAssertTrue(lines.contains("--max-depth"))
        XCTAssertTrue(lines.contains("ENV:RCLONE_CONFIG_R_PASS=OBS"))
    }

    func testFailureIsExplained() throws {
        let (rclone, dir) = try make()
        try "1\nCouldn't connect: 530 Login incorrect".write(
            to: dir.appendingPathComponent("lsf-mode.txt"), atomically: true, encoding: .utf8)
        let r = ConnectionTester.run(binary: rclone.binary, configText: "[r]\ntype = ftp\n", remotePath: "", env: [:])
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.hasPrefix("Authentication failed"), r.message)
        XCTAssertEqual(r.detail, "Couldn't connect: 530 Login incorrect")
    }

    func testTimeoutIsReported() throws {
        let (rclone, dir) = try make()
        try "124".write(to: dir.appendingPathComponent("lsf-mode.txt"), atomically: true, encoding: .utf8)
        let r = ConnectionTester.run(binary: rclone.binary, configText: "[r]\ntype = ftp\n", remotePath: "",
                                     env: [:], timeout: 0.5)
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.contains("did not answer in time"), r.message)
    }

    func testMissingBinaryIsReported() {
        let r = ConnectionTester.run(binary: URL(fileURLWithPath: "/nonexistent/rclone"),
                                     configText: "[r]\ntype = ftp\n", remotePath: "", env: [:])
        XCTAssertFalse(r.ok)
        XCTAssertTrue(r.message.hasPrefix("Could not start rclone"), r.message)
    }
}
