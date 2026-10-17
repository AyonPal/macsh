import Foundation

public struct ConnectionTestResult: Equatable {
    public let ok: Bool
    public let message: String
    /// rclone's own last lines of output for a failure, for diagnostics ("" otherwise).
    public let detail: String

    public init(ok: Bool, message: String, detail: String = "") {
        self.ok = ok
        self.message = message
        self.detail = detail
    }

    public static func success(_ message: String) -> ConnectionTestResult { .init(ok: true, message: message) }
    public static func failure(_ message: String, detail: String = "") -> ConnectionTestResult {
        .init(ok: false, message: message, detail: detail)
    }
}

/// "Test connection": lists the remote's folder with rclone before anything is saved or
/// mounted, and turns rclone's error into a readable message.
public enum ConnectionTester {
    /// Runs `rclone lsf` against `r:<remotePath>` using a throw-away config.
    public static func run(
        binary: URL, configText: String, remotePath: String, env: [String: String],
        timeout: TimeInterval = 30
    ) -> ConnectionTestResult {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-test-\(UUID().uuidString)", isDirectory: true)
        let config = dir.appendingPathComponent("rclone.conf")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try configText.write(to: config, atomically: true, encoding: .utf8)
        } catch {
            return .failure("Could not prepare the test: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: dir) }

        let p = Process()
        p.executableURL = binary
        p.arguments = [
            "lsf", "\(RcloneConfigBuilder.sectionName):\(remotePath)",
            "--config", config.path, "--max-depth", "1",
            "--contimeout", "15s", "--timeout", "20s", "--retries", "1", "--low-level-retries", "1",
        ]
        var environment = ProcessInfo.processInfo.environment
        for (k, v) in env { environment[k] = v }
        p.environment = environment
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure("Could not start rclone: \(error.localizedDescription)") }

        var timedOut = false
        let lock = NSLock()
        let timer = DispatchWorkItem {
            guard p.isRunning else { return }
            lock.lock(); timedOut = true; lock.unlock()
            p.terminate()
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timer)

        // Drain stderr on another thread so a chatty rclone can't fill the pipe and block.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        errDone.wait()
        timer.cancel()

        lock.lock(); let didTimeOut = timedOut; lock.unlock()
        if didTimeOut { return .failure("The server did not answer in time — check host, port and network.") }
        if p.terminationStatus == 0 {
            let count = String(decoding: outData, as: UTF8.self)
                .split(separator: "\n", omittingEmptySubsequences: true).count
            return .success(count == 0 ? "Connected (the folder is empty)"
                                       : "Connected — \(count) item\(count == 1 ? "" : "s") found")
        }
        let stderr = String(decoding: errData, as: UTF8.self)
        let detail = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(3).joined(separator: "\n")
        return .failure(explain(stderr: stderr), detail: detail)
    }

    /// Maps rclone's error output to something a person can act on.
    public static func explain(stderr: String) -> String {
        let text = stderr.lowercased()
        func has(_ needles: String...) -> Bool { needles.contains { text.contains($0) } }

        if has("unable to authenticate", "permission denied (", "login incorrect", "authentication failed",
               "invalidaccesskeyid", "signaturedoesnotmatch", "accessdenied", "access denied", "unauthorized",
               "invalid_grant", "invalid credentials", "bad credentials", "logon_failure", "logon failure", "attempted logon is invalid", "bad username or authentication") {
            return "Authentication failed — check the user, password, key or token."
        }
        if has("certificate", "x509") {
            return "TLS certificate problem — the server's certificate is not trusted."
        }
        if has("no such host", "connection refused", "i/o timeout", "network is unreachable",
               "no route to host", "dial tcp", "context deadline exceeded") {
            return "Could not reach the server — check the host, port and network."
        }
        if has("directory not found", "nosuchbucket", "no such file", "object not found",
               "bucket not found", "couldn't find", "404 not found",
               "bad_network_name", "network name") {
            return "Folder or bucket not found — check the path."
        }
        let tail = stderr.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.suffix(2).joined(separator: "\n")
        return tail.isEmpty ? "The connection test failed." : "The connection test failed:\n\(tail)"
    }
}
