import XCTest
@testable import MacshCore

final class OAuthParseTests: XCTestCase {
    private let json = #"{"access_token":"AT","token_type":"Bearer","refresh_token":"RT","expiry":"2030-01-01T00:00:00Z"}"#

    func testParsesTokenBetweenMarkers() {
        let out = "2026/10/16 NOTICE: Make sure your Redirect URL is set\nWaiting for code...\nPaste the following into your remote machine --->\n\(json)\n<---End paste\n"
        XCTAssertEqual(OAuthAuthorizer.parseToken(from: out), json)
    }

    func testParsesMultiLineTokenBetweenMarkers() {
        let out = "--->\n{\n \"access_token\": \"AT\"\n}\n<---End paste"
        let token = OAuthAuthorizer.parseToken(from: out)
        XCTAssertNotNil(token)
        XCTAssertTrue(token!.contains("access_token"))
    }

    func testFallsBackToBareJSONLine() {
        XCTAssertEqual(OAuthAuthorizer.parseToken(from: "noise\n  \(json)  \nmore"), json)
    }

    func testRejectsOutputWithoutAToken() {
        XCTAssertNil(OAuthAuthorizer.parseToken(from: ""))
        XCTAssertNil(OAuthAuthorizer.parseToken(from: "Failed to authorize: access denied"))
        XCTAssertNil(OAuthAuthorizer.parseToken(from: "--->\nnot json\n<---End paste"))
        XCTAssertNil(OAuthAuthorizer.parseToken(from: "--->\n{\"foo\":1}\n<---End paste"))
    }

    func testConfigReaderFindsValueInSection() {
        let text = "[other]\ntoken = no\n[r]\ntype = drive\ntoken = {\"access_token\":\"X\"}\nscope = drive\n"
        XCTAssertEqual(RcloneConfigReader.value(of: "token", in: text), "{\"access_token\":\"X\"}")
        XCTAssertEqual(RcloneConfigReader.value(of: "scope", in: text), "drive")
        XCTAssertNil(RcloneConfigReader.value(of: "missing", in: text))
        XCTAssertEqual(RcloneConfigReader.value(of: "token", in: text, section: "other"), "no")
    }

    func testErrorsHaveReadableDescriptions() {
        XCTAssertEqual(OAuthError.cancelled.errorDescription, "Sign-in cancelled")
        XCTAssertTrue(OAuthError.timedOut.errorDescription!.contains("timed out"))
        XCTAssertEqual(OAuthError.failed("denied").errorDescription, "Sign-in failed: denied")
        XCTAssertEqual(OAuthError.failed("").errorDescription, "Sign-in failed")
        XCTAssertTrue(OAuthError.launchFailed("x").errorDescription!.contains("x"))
    }
}

final class OAuthAuthorizerTests: XCTestCase {
    private func make() throws -> (FakeRclone, URL) {
        try FakeRclone.requirePython()
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (try FakeRclone.make(in: dir), dir)
    }

    func testAuthorizeReturnsTokenAndPassesArguments() async throws {
        let (rclone, _) = try make()
        let token = try await OAuthAuthorizer().authorize(
            binary: rclone.binary, backend: "drive", clientID: "cid", clientSecret: "csecret", scope: "drive.readonly")
        XCTAssertTrue(token.contains(#""refresh_token":"RT""#))
        let lines = rclone.recordedLines()
        XCTAssertEqual(Array(lines.prefix(4)), ["authorize", "drive", "cid", "csecret"])
        XCTAssertTrue(lines.contains("ENV:RCLONE_DRIVE_SCOPE=drive.readonly"))
    }

    func testClientIDWithoutSecretIsRefusedAndRcloneIsNotLaunched() async throws {
        // It used to be dropped silently, authorizing against rclone's shared client; the
        // resulting token stops refreshing once the mount uses the custom client.
        let (rclone, _) = try make()
        do {
            _ = try await OAuthAuthorizer().authorize(binary: rclone.binary, backend: "drive", clientID: "cid")
            XCTFail("expected a refusal")
        } catch OAuthError.failed(let message) {
            XCTAssertTrue(message.contains("client secret"), message)
        }
        XCTAssertTrue(rclone.recordedLines().isEmpty, "rclone must not run with half a client")
    }

    func testFailureSurfacesRcloneMessage() async throws {
        let (rclone, dir) = try make()
        try "fail".write(to: dir.appendingPathComponent("authorize-mode.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await OAuthAuthorizer().authorize(binary: rclone.binary, backend: "drive")
            XCTFail("expected failure")
        } catch let OAuthError.failed(msg) {
            XCTAssertTrue(msg.contains("access denied"), msg)
        }
    }

    func testTimeoutTerminatesRclone() async throws {
        let (rclone, dir) = try make()
        try "hang".write(to: dir.appendingPathComponent("authorize-mode.txt"), atomically: true, encoding: .utf8)
        do {
            _ = try await OAuthAuthorizer().authorize(binary: rclone.binary, backend: "drive", timeout: 0.5)
            XCTFail("expected timeout")
        } catch {
            XCTAssertEqual(error as? OAuthError, .timedOut)
        }
    }

    func testCancelStopsPendingAuthorize() async throws {
        let (rclone, dir) = try make()
        try "hang".write(to: dir.appendingPathComponent("authorize-mode.txt"), atomically: true, encoding: .utf8)
        let auth = OAuthAuthorizer()
        let task = Task { try await auth.authorize(binary: rclone.binary, backend: "drive") }
        try await Task.sleep(nanoseconds: 700_000_000)
        auth.cancel()
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? OAuthError, .cancelled)
        }
    }

    func testMissingBinaryReportsLaunchFailure() async {
        do {
            _ = try await OAuthAuthorizer().authorize(binary: URL(fileURLWithPath: "/nonexistent/rclone"), backend: "drive")
            XCTFail("expected failure")
        } catch {
            guard case OAuthError.launchFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testClientIDWithoutSecretIsRefusedInsteadOfUsingTheSharedClient() async {
        let binary = URL(fileURLWithPath: "/usr/bin/false")     // must never be launched
        for (id, secret) in [("my-id.apps.googleusercontent.com", ""), ("my-id", "   "), ("", "my-secret"), ("  ", "my-secret")] {
            do {
                _ = try await OAuthAuthorizer().authorize(binary: binary, backend: "drive", clientID: id, clientSecret: secret)
                XCTFail("expected a refusal for id=\(id) secret=\(secret)")
            } catch OAuthError.failed(let message) {
                XCTAssertTrue(message.contains("client"), message)
            } catch {
                XCTFail("unexpected error \(error)")
            }
        }
    }
}
