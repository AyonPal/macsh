import Foundation
import Darwin

public final class RcloneProcess {
    public struct Spawned {
        public let process: Process
        public let port: Int
        public let user: String
        public let password: String
    }

    public enum SpawnError: Error {
        case failedToWriteConfig(Error)
        case noFreePort
        case launchFailed(Error)
    }

    private let binary: URL
    private let logFile: URL

    public init(binary: URL, logFile: URL) {
        self.binary = binary
        self.logFile = logFile
    }

    /// Writes `configText` to a temp file, picks a free localhost port, generates random local creds,
    /// and starts `rclone serve webdav <remoteName>:<remotePath> --addr 127.0.0.1:<port> --user <u> --pass <p>`.
    /// `passwordEnvValue` (if non-nil) is set as `passwordEnvName` for the child so rclone can use it for SFTP auth.
    /// rclone serve flags that make remote-side changes appear quickly. Default rclone
    /// caches dir listings for 5 minutes, which feels broken for personal sync use.
    private static let liveUpdateArgs = ["--dir-cache-time", "10s", "--vfs-fast-fingerprint"]

    public func spawnWebDAVServe(
        remoteName: String,
        remotePath: String,
        configText: String,
        baseurl: String,
        liveUpdates: Bool,
        envOverrides: [String: String] = [:]
    ) throws -> Spawned {
        var extra = ["--vfs-cache-mode", "writes", "--baseurl", baseurl]
        if liveUpdates { extra.append(contentsOf: Self.liveUpdateArgs) }
        return try spawn(
            serveSubcommand: "webdav",
            extraServeArgs: extra,
            remoteName: remoteName,
            remotePath: remotePath,
            configText: configText,
            envOverrides: envOverrides,
            includeAuth: true
        )
    }

    /// Spawns `rclone serve nfs <remote>:<path> --addr 127.0.0.1:<port>`.
    /// NFS does not use HTTP basic auth; the returned `user`/`password` are blanks.
    public func spawnNFSServe(
        remoteName: String,
        remotePath: String,
        configText: String,
        liveUpdates: Bool,
        envOverrides: [String: String] = [:]
    ) throws -> Spawned {
        var extra = ["--vfs-cache-mode", "writes"]
        if liveUpdates { extra.append(contentsOf: Self.liveUpdateArgs) }
        return try spawn(
            serveSubcommand: "nfs",
            extraServeArgs: extra,
            remoteName: remoteName,
            remotePath: remotePath,
            configText: configText,
            envOverrides: envOverrides,
            includeAuth: false
        )
    }

    private func spawn(
        serveSubcommand: String,
        extraServeArgs: [String],
        remoteName: String,
        remotePath: String,
        configText: String,
        envOverrides: [String: String],
        includeAuth: Bool
    ) throws -> Spawned {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-rclone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        let configURL = tmpDir.appendingPathComponent("rclone.conf")
        do { try configText.write(to: configURL, atomically: true, encoding: .utf8) }
        catch { throw SpawnError.failedToWriteConfig(error) }

        let port = try Self.findFreePort()
        let user = includeAuth ? "macsh-\(UUID().uuidString.prefix(8))" : ""
        let password = includeAuth ? UUID().uuidString : ""

        let process = Process()
        process.executableURL = binary
        var args: [String] = [
            "serve", serveSubcommand,
            "\(remoteName):\(remotePath)",
            "--config", configURL.path,
            "--addr", "127.0.0.1:\(port)",
        ]
        if includeAuth {
            args.append(contentsOf: ["--user", user, "--pass", password])
        }
        args.append(contentsOf: extraServeArgs)
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        for (k, v) in envOverrides { env[k] = v }
        process.environment = env

        FileManager.default.createFile(atPath: logFile.path, contents: nil)
        let logHandle = try FileHandle(forWritingTo: logFile)
        process.standardOutput = logHandle
        process.standardError = logHandle

        do { try process.run() }
        catch { throw SpawnError.launchFailed(error) }

        return Spawned(process: process, port: port, user: user, password: password)
    }

    /// Runs `rclone obscure <plaintext>` and returns the obscured form. rclone's env-var
    /// override for a password expects the obscured form (the same one used in config files);
    /// passing plaintext makes rclone fail with "input too short when revealing password".
    public static func obscure(plaintext: String, binary: URL) throws -> String {
        let p = Process()
        p.executableURL = binary
        p.arguments = ["obscure", plaintext]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }

    private static func findFreePort() throws -> Int {
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw SpawnError.noFreePort }
        defer { close(sock) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bindResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(sock, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw SpawnError.noFreePort }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let getResult = withUnsafeMutablePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(sock, sockPtr, &len)
            }
        }
        guard getResult == 0 else { throw SpawnError.noFreePort }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}
