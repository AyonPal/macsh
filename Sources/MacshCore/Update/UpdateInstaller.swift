import Foundation
import CryptoKit

/// Downloads an update DMG, checks it, and swaps the new app over the running one.
public enum UpdateInstaller {
    public enum InstallError: LocalizedError, Equatable {
        case downloadFailed(Int)
        case checksumMismatch
        case notWritable(String)
        case mountFailed(String)
        case appNotFound(String)
        case replaceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .downloadFailed(let code): return "The download failed (HTTP \(code))."
            case .checksumMismatch: return "The downloaded file does not match its published checksum, so it was discarded."
            case .notWritable(let dir):
                return "macsh cannot write to \(dir). Move macsh to /Applications (or another folder you can write to) and try again."
            case .mountFailed(let m): return "Could not open the downloaded disk image: \(m)"
            case .appNotFound(let n): return "The downloaded disk image does not contain \(n)."
            case .replaceFailed(let m): return "Could not replace the installed app: \(m)"
            }
        }
    }

    // MARK: Download and verify

    /// Downloads `asset` into `directory` and returns the file URL.
    public static func download(_ asset: ReleaseAsset, to directory: URL, session: URLSession = .shared) async throws -> URL {
        var req = URLRequest(url: asset.downloadURL)
        req.setValue("macsh-updater", forHTTPHeaderField: "User-Agent")
        let (tmp, response) = try await session.download(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            try? FileManager.default.removeItem(at: tmp)
            throw InstallError.downloadFailed(status)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(asset.name)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    /// Lowercase hex SHA-256 of a file, read in chunks.
    public static func sha256(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Throws `checksumMismatch` unless the file matches `expected` ("sha256:<hex>" or bare hex).
    /// A nil or non-SHA-256 `expected` skips the check (GitHub does not always report a digest).
    public static func verify(file: URL, expected: String?) throws {
        guard var want = expected?.lowercased(), !want.isEmpty else { return }
        if want.hasPrefix("sha256:") { want = String(want.dropFirst(7)) }
        else if want.contains(":") { return }
        guard try sha256(of: file) == want else { throw InstallError.checksumMismatch }
    }

    // MARK: Install

    /// True when the folder holding the app can be written to (needed to swap the bundle).
    public static func canReplace(_ appURL: URL) -> Bool {
        FileManager.default.isWritableFile(atPath: appURL.deletingLastPathComponent().path)
    }

    /// Opens the DMG, copies `<appName>` out of it into `directory` and unmounts it.
    public static func extractApp(fromDMG dmg: URL, appName: String, into directory: URL) throws -> URL {
        let mount = FileManager.default.temporaryDirectory.appendingPathComponent("macsh-update-mount-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        let attach = run("/usr/bin/hdiutil", ["attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path])
        guard attach.status == 0 else {
            try? FileManager.default.removeItem(at: mount)
            throw InstallError.mountFailed(attach.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        defer {
            _ = run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
            try? FileManager.default.removeItem(at: mount)
        }
        let source = mount.appendingPathComponent(appName)
        guard FileManager.default.fileExists(atPath: source.path) else { throw InstallError.appNotFound(appName) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dest = directory.appendingPathComponent(appName)
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: source, to: dest)
        return dest
    }

    /// Removes the download quarantine flag so Gatekeeper does not block the unsigned new build.
    public static func clearQuarantine(_ app: URL) {
        _ = run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", app.path])
    }

    /// Replaces `current` with `new` (same volume), keeping nothing of the old bundle.
    public static func replaceApp(at current: URL, with new: URL) throws {
        do {
            _ = try FileManager.default.replaceItemAt(current, withItemAt: new)
        } catch {
            throw InstallError.replaceFailed(error.localizedDescription)
        }
    }

    /// Verifies the DMG and installs the app it contains over `current`. The new copy is staged
    /// next to the old one so the swap never crosses volumes. Does not relaunch.
    public static func install(dmg: URL, expectedDigest: String?, over current: URL) throws {
        try verify(file: dmg, expected: expectedDigest)
        guard canReplace(current) else {
            throw InstallError.notWritable(current.deletingLastPathComponent().path)
        }
        let staging = current.deletingLastPathComponent().appendingPathComponent(".macsh-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staging) }
        let staged = try extractApp(fromDMG: dmg, appName: current.lastPathComponent, into: staging)
        clearQuarantine(staged)
        try replaceApp(at: current, with: staged)
    }

    /// A detached process that waits for this app to quit, then opens the (new) app.
    public static func relaunchProcess(appURL: URL) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let path = appURL.path.replacingOccurrences(of: "'", with: "'\\''")
        p.arguments = ["-c", "sleep 1; /usr/bin/open -n '\(path)'"]
        return p
    }

    // MARK: Process helper

    private static func run(_ exe: String, _ args: [String]) -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        let err = Pipe()
        p.standardError = err
        p.standardOutput = Pipe()
        do { try p.run() } catch { return (-1, error.localizedDescription) }
        let data = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
