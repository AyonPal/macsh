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

public enum HostKeyError: Error, LocalizedError {
    case keyscanFailed(stderr: String)
    case rejectedByUser
    case fingerprintComputationFailed

    public var errorDescription: String? {
        switch self {
        case .keyscanFailed(let stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return "Could not read the server's host key (ssh-keyscan failed)"
                + (detail.isEmpty ? ". The server may be unreachable or not answering SSH." : ": \(detail)")
        case .rejectedByUser:
            return "Host key was not accepted"
        case .fingerprintComputationFailed:
            return "Could not compute the host key fingerprint"
        }
    }
}

@MainActor
public final class HostKeyVerifier {
    nonisolated public let knownHostsPath: String
    private let prompter: HostKeyPrompter

    public init(knownHostsPath: String, prompter: HostKeyPrompter) {
        self.knownHostsPath = knownHostsPath
        self.prompter = prompter
        if !FileManager.default.fileExists(atPath: knownHostsPath) {
            FileManager.default.createFile(atPath: knownHostsPath, contents: Data())
        }
    }

    /// Result of the blocking part of the host-key check (`ssh-keyscan`, fingerprints).
    public struct Inspection {
        enum Outcome {
            case trusted
            case firstContact(line: String, fingerprint: String)
            case changed(oldFingerprint: String, newFingerprint: String)
        }
        let host: String
        let port: Int
        let liveLines: [String]
        let outcome: Outcome
    }

    /// TOFU: if `host` (with `port`) isn't in known_hosts, ssh-keyscan it, ask the user
    /// to confirm the fingerprint, and append on accept. If present but the live key
    /// differs, ask the user about the change.
    ///
    /// Blocks on `ssh-keyscan`. UI code should call `inspect` off the main thread and then
    /// `resolve` on it, as `SessionManager.mount` does.
    public func ensureKnown(host: String, port: Int) throws {
        try resolve(try inspect(host: host, port: port))
    }

    /// Blocking: runs `ssh-keyscan` / `ssh-keygen`. Safe to call from a background thread.
    nonisolated public func inspect(host: String, port: Int) throws -> Inspection {
        let existing = readExistingLines(host: host, port: port)
        let liveLines = try keyscan(host: host, port: port)
        guard !liveLines.isEmpty else {
            throw HostKeyError.keyscanFailed(stderr: "no host keys returned by ssh-keyscan")
        }
        if existing.isEmpty {
            let line = liveLines[0]
            return Inspection(host: host, port: port, liveLines: liveLines,
                              outcome: .firstContact(line: line, fingerprint: try fingerprint(forKnownHostsLine: line)))
        }
        if !liveLines.contains(where: { existing.contains($0) }) {
            let oldFp = (try? fingerprint(forKnownHostsLine: existing.first ?? "")) ?? "<unknown>"
            let newFp = (try? fingerprint(forKnownHostsLine: liveLines.first ?? "")) ?? "<unknown>"
            return Inspection(host: host, port: port, liveLines: liveLines,
                              outcome: .changed(oldFingerprint: oldFp, newFingerprint: newFp))
        }
        return Inspection(host: host, port: port, liveLines: liveLines, outcome: .trusted)
    }

    /// Main actor: shows the confirmation dialog if needed and updates known_hosts.
    public func resolve(_ inspection: Inspection) throws {
        switch inspection.outcome {
        case .trusted:
            return
        case .firstContact(let line, let fp):
            var decision = HostKeyDecision(host: inspection.host, port: inspection.port,
                                           fingerprintSHA256: fp, knownHostsLine: line)
            prompter.confirm(&decision)
            guard decision.accepted else { throw HostKeyError.rejectedByUser }
            try append(lines: inspection.liveLines)
        case .changed(let oldFp, let newFp):
            let accept = prompter.confirmChange(host: inspection.host, port: inspection.port,
                                                oldFingerprint: oldFp, newFingerprint: newFp)
            guard accept else { throw HostKeyError.rejectedByUser }
            try replaceEntries(host: inspection.host, port: inspection.port, withLines: inspection.liveLines)
        }
    }

    nonisolated private func readExistingLines(host: String, port: Int) -> [String] {
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

    nonisolated private func keyscan(host: String, port: Int) throws -> [String] {
        let exe = "/usr/bin/ssh-keyscan"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
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

    nonisolated private func fingerprint(forKnownHostsLine line: String) throws -> String {
        // Write the line to a temp file and run ssh-keygen -lf <file>.
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
}
