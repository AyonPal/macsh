import XCTest
@testable import MacshCore

@MainActor
final class ClearErrorTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-err-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func write(_ name: String, _ text: String) throws -> String {
        let url = dir.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    // MARK: KeyFileValidator

    func testAcceptsOpenSSHPrivateKey() throws {
        let p = try write("id", "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n-----END OPENSSH PRIVATE KEY-----\n")
        XCTAssertNil(KeyFileValidator.validate(path: p))
    }

    func testAcceptsPEMRSAKey() throws {
        let p = try write("rsa", "-----BEGIN RSA PRIVATE KEY-----\nabc\n-----END RSA PRIVATE KEY-----\n")
        XCTAssertNil(KeyFileValidator.validate(path: p))
    }

    func testRejectsPublicKey() throws {
        let p = try write("id.pub", "ssh-ed25519 AAAAC3Nza user@host\n")
        XCTAssertTrue(KeyFileValidator.validate(path: p)?.contains("public key") == true)
    }

    func testRejectsMissingFile() {
        XCTAssertTrue(KeyFileValidator.validate(path: dir.appendingPathComponent("nope").path)?.contains("not found") == true)
    }

    func testRejectsDirectory() {
        XCTAssertNotNil(KeyFileValidator.validate(path: dir.path))
    }

    func testRejectsRandomFile() throws {
        let p = try write("notes.txt", "hello\n")
        XCTAssertNotNil(KeyFileValidator.validate(path: p))
    }

    // MARK: HostKeyError

    func testHostKeyErrorsHaveReadableMessages() {
        let e = HostKeyError.keyscanFailed(stderr: "")
        XCTAssertTrue(e.localizedDescription.contains("host key"))
        XCTAssertFalse(e.localizedDescription.contains("error 0"))
        XCTAssertTrue(HostKeyError.keyscanFailed(stderr: "timed out\n").localizedDescription.contains("timed out"))
        XCTAssertEqual(HostKeyError.rejectedByUser.localizedDescription, "Host key was not accepted")
    }

    // MARK: log tail

    func testLogTailReturnsLastLines() throws {
        let p = try write("r.log", "one\n\ntwo\nthree\nfour\n")
        XCTAssertEqual(SessionManager.logTail(of: URL(fileURLWithPath: p), lines: 2), "three\nfour")
    }

    func testLogTailNilForMissingOrEmpty() throws {
        XCTAssertNil(SessionManager.logTail(of: dir.appendingPathComponent("missing.log")))
        let p = try write("empty.log", "\n\n")
        XCTAssertNil(SessionManager.logTail(of: URL(fileURLWithPath: p)))
    }
}
