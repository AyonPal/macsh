import XCTest
@testable import MacshCore

private final class FakePrompter: HostKeyPrompter {
    var acceptNew = true
    var acceptChange = true
    private(set) var confirmCalls = 0
    private(set) var changeCalls = 0
    private(set) var lastDecision: HostKeyDecision?
    private(set) var lastOldFingerprint: String?
    private(set) var lastNewFingerprint: String?

    func confirm(_ decision: inout HostKeyDecision) {
        confirmCalls += 1
        lastDecision = decision
        decision.accepted = acceptNew
    }

    func confirmChange(host: String, port: Int, oldFingerprint: String, newFingerprint: String) -> Bool {
        changeCalls += 1
        lastOldFingerprint = oldFingerprint
        lastNewFingerprint = newFingerprint
        return acceptChange
    }
}

/// Throwaway unprivileged sshd on localhost so ssh-keyscan has something real to talk to.
private final class LocalSSHD {
    let port: Int
    private let process: Process

    init(port: Int, process: Process) {
        self.port = port
        self.process = process
    }

    func stop() { process.terminate() }

    static func start(in dir: URL) throws -> LocalSSHD {
        let sshd = "/usr/sbin/sshd"
        let keygen = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: sshd),
              FileManager.default.isExecutableFile(atPath: keygen) else {
            throw XCTSkip("sshd/ssh-keygen not available")
        }
        let hostKey = dir.appendingPathComponent("host_ed25519").path
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: keygen)
        gen.arguments = ["-q", "-t", "ed25519", "-N", "", "-f", hostKey]
        try gen.run()
        gen.waitUntilExit()
        guard gen.terminationStatus == 0 else { throw XCTSkip("could not generate host key") }

        for _ in 0..<5 {
            let port = Int.random(in: 20000...40000)
            let p = Process()
            p.executableURL = URL(fileURLWithPath: sshd)
            p.arguments = ["-D", "-f", "/dev/null", "-h", hostKey, "-p", String(port),
                           "-o", "ListenAddress=127.0.0.1", "-o", "PidFile=none", "-o", "UsePAM=no"]
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            do { try p.run() } catch { continue }
            if waitForPort(port, alive: { p.isRunning }) {
                return LocalSSHD(port: port, process: p)
            }
            p.terminate()
        }
        throw XCTSkip("could not start a local sshd")
    }

    private static func waitForPort(_ port: Int, alive: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, alive() {
            let sock = socket(AF_INET, SOCK_STREAM, 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = UInt16(port).bigEndian
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let rc = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            close(sock)
            if rc == 0 { return true }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return false
    }
}

@MainActor
final class HostKeyVerifierTests: XCTestCase {
    private func knownHostsFile() throws -> (dir: URL, path: String) {
        let dir = try makeTempDir()
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (dir, dir.appendingPathComponent("known_hosts").path)
    }

    private func startSSHD(in dir: URL) throws -> LocalSSHD {
        let server = try LocalSSHD.start(in: dir)
        addTeardownBlock { server.stop() }
        return server
    }

    func testInitCreatesKnownHostsFile() throws {
        let (_, path) = try knownHostsFile()
        _ = HostKeyVerifier(knownHostsPath: path, prompter: FakePrompter())
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))
    }

    func testUnreachableHostThrowsKeyscanFailed() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ssh-keyscan") else {
            throw XCTSkip("ssh-keyscan not available")
        }
        let (_, path) = try knownHostsFile()
        let prompter = FakePrompter()
        let verifier = HostKeyVerifier(knownHostsPath: path, prompter: prompter)
        XCTAssertThrowsError(try verifier.ensureKnown(host: "127.0.0.1", port: 1)) { error in
            guard case HostKeyError.keyscanFailed = error else {
                return XCTFail("expected keyscanFailed, got \(error)")
            }
        }
        XCTAssertEqual(prompter.confirmCalls, 0)
    }

    func testFirstContactAcceptedIsAppended() throws {
        let (dir, path) = try knownHostsFile()
        let server = try startSSHD(in: dir)
        let prompter = FakePrompter()
        let verifier = HostKeyVerifier(knownHostsPath: path, prompter: prompter)

        try verifier.ensureKnown(host: "127.0.0.1", port: server.port)

        XCTAssertEqual(prompter.confirmCalls, 1)
        XCTAssertEqual(prompter.lastDecision?.host, "127.0.0.1")
        XCTAssertEqual(prompter.lastDecision?.port, server.port)
        XCTAssertTrue(prompter.lastDecision?.fingerprintSHA256.hasPrefix("SHA256:") == true)
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertTrue(contents.contains("[127.0.0.1]:\(server.port) ssh-ed25519 "))
    }

    func testFirstContactRejectedThrowsAndWritesNothing() throws {
        let (dir, path) = try knownHostsFile()
        let server = try startSSHD(in: dir)
        let prompter = FakePrompter()
        prompter.acceptNew = false
        let verifier = HostKeyVerifier(knownHostsPath: path, prompter: prompter)

        XCTAssertThrowsError(try verifier.ensureKnown(host: "127.0.0.1", port: server.port)) { error in
            guard case HostKeyError.rejectedByUser = error else {
                return XCTFail("expected rejectedByUser, got \(error)")
            }
        }
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "")
    }

    func testKnownHostDoesNotPromptAgain() throws {
        let (dir, path) = try knownHostsFile()
        let server = try startSSHD(in: dir)
        let prompter = FakePrompter()
        let verifier = HostKeyVerifier(knownHostsPath: path, prompter: prompter)

        try verifier.ensureKnown(host: "127.0.0.1", port: server.port)
        try verifier.ensureKnown(host: "127.0.0.1", port: server.port)

        XCTAssertEqual(prompter.confirmCalls, 1)
        XCTAssertEqual(prompter.changeCalls, 0)
    }

    private func seedStaleKey(path: String, port: Int) throws -> String {
        let other = try SSHKeygen.generateEd25519(comment: "old")
        let line = "[127.0.0.1]:\(port) \(other.publicKeyOpenSSH)"
        try (line + "\nother.example.com ssh-ed25519 AAAAkeep\n").write(toFile: path, atomically: true, encoding: .utf8)
        return other.publicKeyOpenSSH
    }

    func testChangedKeyAcceptedReplacesEntry() throws {
        let (dir, path) = try knownHostsFile()
        let server = try startSSHD(in: dir)
        let oldKey = try seedStaleKey(path: path, port: server.port)
        let prompter = FakePrompter()
        let verifier = HostKeyVerifier(knownHostsPath: path, prompter: prompter)

        try verifier.ensureKnown(host: "127.0.0.1", port: server.port)

        XCTAssertEqual(prompter.changeCalls, 1)
        XCTAssertEqual(prompter.confirmCalls, 0)
        XCTAssertNotEqual(prompter.lastOldFingerprint, prompter.lastNewFingerprint)
        XCTAssertTrue(prompter.lastOldFingerprint?.hasPrefix("SHA256:") == true)
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        XCTAssertFalse(contents.contains(oldKey))
        XCTAssertTrue(contents.contains("[127.0.0.1]:\(server.port) ssh-ed25519 "))
        XCTAssertTrue(contents.contains("other.example.com ssh-ed25519 AAAAkeep"), "unrelated entries must survive")
    }

    func testChangedKeyRejectedKeepsOldEntry() throws {
        let (dir, path) = try knownHostsFile()
        let server = try startSSHD(in: dir)
        let oldKey = try seedStaleKey(path: path, port: server.port)
        let prompter = FakePrompter()
        prompter.acceptChange = false
        let verifier = HostKeyVerifier(knownHostsPath: path, prompter: prompter)

        XCTAssertThrowsError(try verifier.ensureKnown(host: "127.0.0.1", port: server.port)) { error in
            guard case HostKeyError.rejectedByUser = error else {
                return XCTFail("expected rejectedByUser, got \(error)")
            }
        }
        XCTAssertTrue(try String(contentsOfFile: path, encoding: .utf8).contains(oldKey))
    }
}
