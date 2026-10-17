import XCTest
@testable import MacshCore

final class SSHKeygenTests: XCTestCase {
    func testGenerateEd25519() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen") else {
            throw XCTSkip("ssh-keygen not available")
        }
        let pair = try SSHKeygen.generateEd25519(comment: "macsh-test")
        XCTAssertTrue(pair.publicKeyOpenSSH.hasPrefix("ssh-ed25519 "))
        XCTAssertTrue(pair.publicKeyOpenSSH.hasSuffix("macsh-test"))
        XCTAssertTrue(pair.privateKeyPEM.contains("PRIVATE KEY"))
        XCTAssertTrue(pair.fingerprintSHA256.hasPrefix("SHA256:"))
    }

    func testGeneratedKeysAreUnique() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keygen") else {
            throw XCTSkip("ssh-keygen not available")
        }
        let a = try SSHKeygen.generateEd25519()
        let b = try SSHKeygen.generateEd25519()
        XCTAssertNotEqual(a.fingerprintSHA256, b.fingerprintSHA256)
    }
}
