import Foundation

public struct HostKeyDecision {
    public let host: String
    public let port: Int
    public let fingerprintSHA256: String
    public let knownHostsLine: String
    /// Set by the consumer (UI) to true to accept and append to known_hosts.
    public var accepted: Bool = false
}

public protocol HostKeyPrompter: AnyObject {
    /// Synchronously prompt the user to confirm a new host key. Mutate `decision.accepted`.
    func confirm(_ decision: inout HostKeyDecision)
    /// Synchronously prompt the user about a CHANGED host key (potentially malicious).
    func confirmChange(host: String, port: Int, oldFingerprint: String, newFingerprint: String) -> Bool
}

public enum HostKeyError: Error {
    case keyscanFailed(stderr: String)
    case rejectedByUser
    case fingerprintComputationFailed
}

extension HostKeyError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .keyscanFailed(let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty
                ? "Could not scan the server's host key. Check that the host is reachable on the configured port."
                : "Could not scan the server's host key: \(detail)"
        case .rejectedByUser:
            return "Connection cancelled: the server's host key was not trusted."
        case .fingerprintComputationFailed:
            return "Could not compute the server's key fingerprint."
        }
    }
}

@MainActor
public final class HostKeyVerifier {
    public let knownHostsPath: String
    private let prompter: HostKeyPrompter

    public init(knownHostsPath: String, prompter: HostKeyPrompter) {
        self.knownHostsPath = knownHostsPath
        self.prompter = prompter
        if !FileManager.default.fileExists(atPath: knownHostsPath) {
            FileManager.default.createFile(atPath: knownHostsPath, contents: Data())
        }
    }

    /// TOFU: if `host` (with `port`) isn't in known_hosts, ssh-keyscan it, ask the user
    /// to confirm the fingerprint, and append on accept. If present but the live key
    /// differs, ask the user about the change.
    /// Heavy work (ssh-keyscan, ssh-keygen) runs off the main actor so UI stays responsive.
    public func ensureKnown(host: String, port: Int) async throws {
        let existing = readExistingLines(host: host, port: port)

        // Run keyscan on a background thread — it blocks waiting for a process.
        let liveLines: [String]
        do {
            liveLines = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try Self.runKeyscan(host: host, port: port)) }
                    catch { cont.resume(throwing: error) }
                }
            }
        } catch {
            // For already-trusted hosts, tolerate keyscan failures (transient network,
            // servers that block port scans, etc.) and proceed with the cached key.
            if !existing.isEmpty { return }
            throw error
        }

        guard !liveLines.isEmpty else {
            if !existing.isEmpty { return }
            throw HostKeyError.keyscanFailed(stderr: "no host keys returned by ssh-keyscan")
        }

        if existing.isEmpty {
            // First contact — compute fingerprint off main thread, then ask user.
            let line = liveLines[0]
            let fp: String = try await withCheckedThrowingContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    do { cont.resume(returning: try Self.runFingerprint(forKnownHostsLine: line)) }
                    catch { cont.resume(throwing: error) }
                }
            }
            // Back on MainActor — show dialog.
            var decision = HostKeyDecision(host: host, port: port, fingerprintSHA256: fp, knownHostsLine: line)
            prompter.confirm(&decision)
            guard decision.accepted else { throw HostKeyError.rejectedByUser }
            try append(lines: liveLines)
        } else if !liveLines.contains(where: { existing.contains($0) }) {
            // Changed key — compute both fingerprints off main thread, then ask user.
            let oldLine = existing.first ?? ""
            let newLine = liveLines.first ?? ""
            let (oldFp, newFp): (String, String) = await withCheckedContinuation { cont in
                DispatchQueue.global(qos: .userInitiated).async {
                    let o = (try? Self.runFingerprint(forKnownHostsLine: oldLine)) ?? "<unknown>"
                    let n = (try? Self.runFingerprint(forKnownHostsLine: newLine)) ?? "<unknown>"
                    cont.resume(returning: (o, n))
                }
            }
            // Back on MainActor — show dialog.
            let accept = prompter.confirmChange(host: host, port: port, oldFingerprint: oldFp, newFingerprint: newFp)
            guard accept else { throw HostKeyError.rejectedByUser }
            try replaceEntries(host: host, port: port, withLines: liveLines)
        }
        // else: already-trusted key still in use, nothing to do.
    }

    // MARK: - Private helpers (nonisolated static — safe to call from background threads)

    private nonisolated static func runKeyscan(host: String, port: Int) throws -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keyscan")
        p.arguments = ["-T", "5", "-p", String(port), "-t", "ed25519,rsa,ecdsa", host]
        let outPipe = Pipe(); let errPipe = Pipe()
        p.standardOutput = outPipe; p.standardError = errPipe
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw HostKeyError.keyscanFailed(stderr: err)
        }
        let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return out.split(separator: "\n")
            .map { String($0) }
            .filter { !$0.hasPrefix("#") && !$0.isEmpty }
    }

    private nonisolated static func runFingerprint(forKnownHostsLine line: String) throws -> String {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-fp-\(UUID().uuidString)")
        try line.write(to: tmp, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        p.arguments = ["-lf", tmp.path]
        let outPipe = Pipe(); p.standardOutput = outPipe; p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw HostKeyError.fingerprintComputationFailed }
        let raw = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let parts = raw.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        return parts.count >= 2 ? String(parts[1]) : raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func readExistingLines(host: String, port: Int) -> [String] {
        guard let raw = try? String(contentsOfFile: knownHostsPath, encoding: .utf8) else { return [] }
        let prefix = port == 22 ? host : "[\(host)]:\(port)"
        return raw.split(separator: "\n").map(String.init).filter { line in
            line.hasPrefix("\(prefix) ")
        }
    }

    private func append(lines: [String]) throws {
        let blob = lines.joined(separator: "\n") + "\n"
        let url = URL(fileURLWithPath: knownHostsPath)
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            try handle.seekToEnd()
            if let data = blob.data(using: .utf8) { try handle.write(contentsOf: data) }
        } else {
            try blob.write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
        }
    }

    private func replaceEntries(host: String, port: Int, withLines newLines: [String]) throws {
        let raw = (try? String(contentsOfFile: knownHostsPath, encoding: .utf8)) ?? ""
        let prefix = port == 22 ? host : "[\(host)]:\(port)"
        let kept = raw.split(separator: "\n").map(String.init).filter { !$0.hasPrefix("\(prefix) ") }
        let combined = (kept + newLines).joined(separator: "\n") + "\n"
        try combined.write(toFile: knownHostsPath, atomically: true, encoding: .utf8)
    }
}
