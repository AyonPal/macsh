import Foundation

public struct GeneratedKeyPair {
    public let publicKeyOpenSSH: String
    public let privateKeyPEM: String
    public let fingerprintSHA256: String
}

public enum SSHKeygenError: Error {
    case binaryNotFound
    case keygenFailed(stderr: String)
    case readFailed(Error)
}

public enum SSHKeygen {
    /// Generates an ed25519 keypair via /usr/bin/ssh-keygen, returns the material,
    /// then deletes the temp files. Comment defaults to "macsh-<short-id>".
    public static func generateEd25519(comment: String? = nil) throws -> GeneratedKeyPair {
        let keygen = "/usr/bin/ssh-keygen"
        guard FileManager.default.isExecutableFile(atPath: keygen) else {
            throw SSHKeygenError.binaryNotFound
        }
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-keygen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let keyPath = tmpDir.appendingPathComponent("id_ed25519").path
        let pubPath = "\(keyPath).pub"
        let cmt = comment ?? "macsh-\(UUID().uuidString.prefix(8))"

        try run(keygen, args: ["-t", "ed25519", "-N", "", "-C", cmt, "-f", keyPath])

        let priv: String
        let pub: String
        do {
            priv = try String(contentsOfFile: keyPath, encoding: .utf8)
            pub = try String(contentsOfFile: pubPath, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw SSHKeygenError.readFailed(error)
        }

        let fpRaw = try captureStdout(keygen, args: ["-lf", pubPath])
        // ssh-keygen -lf prints e.g. "256 SHA256:abcd... user@host (ED25519)"
        let parts = fpRaw.split(separator: " ", maxSplits: 4, omittingEmptySubsequences: true)
        let fp = parts.count >= 2 ? String(parts[1]) : fpRaw.trimmingCharacters(in: .whitespacesAndNewlines)

        return GeneratedKeyPair(publicKeyOpenSSH: pub, privateKeyPEM: priv, fingerprintSHA256: fp)
    }

    private static func run(_ exe: String, args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            throw SSHKeygenError.keygenFailed(stderr: String(data: data, encoding: .utf8) ?? "")
        }
    }

    private static func captureStdout(_ exe: String, args: [String]) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            throw SSHKeygenError.keygenFailed(stderr: "")
        }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }
}
