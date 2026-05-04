import Foundation
import Darwin
import NetFS

public final class Mounter {
    public enum MountError: LocalizedError {
        case mountpointCreationFailed(String)
        case mountFailed(stderr: String, exitCode: Int32)
        case unmountFailed(stderr: String, exitCode: Int32)
        case netFSFailed(status: Int32)

        public var errorDescription: String? {
            switch self {
            case .mountpointCreationFailed(let msg):
                return "Could not create mountpoint: \(msg)"
            case .mountFailed(let stderr, let code):
                return "mount failed (exit \(code)): \(stderr.isEmpty ? "no stderr output" : stderr)"
            case .unmountFailed(let stderr, let code):
                return "unmount failed (exit \(code)): \(stderr.isEmpty ? "no stderr output" : stderr)"
            case .netFSFailed(let status):
                return "NetFS mount failed (status \(status))"
            }
        }
    }

    public init() {}

    /// Strips characters that can't appear in a macOS volume name (`/`, `:`, NULs)
    /// but otherwise leaves the user's chosen name alone. NetFS uses the URL path as
    /// the default volume name, so the returned string becomes both the rclone
    /// `--baseurl` value and `/Volumes/<name>`.
    public func volumeName(from rawName: String) -> String {
        let trimmed = rawName.trimmingCharacters(in: .whitespaces)
        let cleaned = trimmed.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\0", with: "")
        return cleaned.isEmpty ? "macsh-mount" : cleaned
    }

    /// Mounts a WebDAV server via NetFS.framework. Asks NetAuth/automountd to perform
    /// the mount, which is how Finder mounts WebDAV — no privilege escalation needed
    /// from us, and the entry appears under the system's `/Volumes/`.
    /// Returns the actual mountpoint path chosen by the system.
    public func mountWebDAV(host: String, port: Int, baseurl: String, user: String, password: String) throws -> String {
        // baseurl arrives as an unencoded path like "/My Laptop". Percent-encode for the URL.
        let pathEscaped = baseurl.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? baseurl
        let urlString = "http://\(host):\(port)\(pathEscaped)"
        guard let url = URL(string: urlString) else {
            throw MountError.netFSFailed(status: -1)
        }

        let openOpts = NSMutableDictionary()
        openOpts[kNAUIOptionKey as String] = kNAUIOptionNoUI as String
        openOpts[kNetFSAllowLoopbackKey as String] = true

        let mountOpts = NSMutableDictionary()

        var mountpoints: Unmanaged<CFArray>? = nil
        let status = NetFSMountURLSync(
            url as CFURL,
            nil,
            user as CFString,
            password as CFString,
            openOpts as CFMutableDictionary,
            mountOpts as CFMutableDictionary,
            &mountpoints
        )
        if status != 0 {
            throw MountError.netFSFailed(status: status)
        }
        guard let mps = mountpoints?.takeRetainedValue() as? [String], let first = mps.first else {
            throw MountError.netFSFailed(status: -1)
        }
        return first
    }

    /// Calls `mount_nfs -o <opts> <host>:<exportPath> <mountpoint>`.
    /// Defaults: NFSv3, no root squash, locallocks, vers=3 (rclone serve nfs default).
    /// NFS still goes through the legacy exec path; NetFS supports NFS too but the URL
    /// shape and option keys differ from the WebDAV path — left as a follow-up.
    public func mountNFS(host: String, port: Int, exportPath: String, name: String, mountpoint: String) throws {
        let source = "\(host):\(exportPath)"
        let opts = "vers=3,tcp,port=\(port),mountport=\(port),nolocks,locallocks,soft,timeo=30,nfc,rsize=131072,wsize=131072"
        try run(
            "/sbin/mount_nfs",
            args: ["-o", opts, source, mountpoint],
            failure: MountError.mountFailed
        )
    }

    public func resolveMountpoint(name: String) throws -> String {
        let fm = FileManager.default
        var candidate = "/Volumes/\(name)"
        var counter = 2
        while fm.fileExists(atPath: candidate) {
            candidate = "/Volumes/\(name)-\(counter)"
            counter += 1
        }
        do {
            try fm.createDirectory(atPath: candidate, withIntermediateDirectories: false)
        } catch {
            throw MountError.mountpointCreationFailed(error.localizedDescription)
        }
        return candidate
    }

    /// If `/Volumes/<volname>` is currently mounted from a `http://127.0.0.1:<port>/...`
    /// source (the shape macsh produces), unmount it and SIGTERM the orphan rclone
    /// process listening on that port. Returns true if anything was reconciled.
    ///
    /// Called at app launch before `autoMountAll` so a prior macsh instance that
    /// died via SIGKILL/crash doesn't produce duplicate `/Volumes/<name>-1`,
    /// `<name>-2` mounts on every subsequent launch.
    @discardableResult
    public func reconcileStaleMount(volumeName: String) -> Bool {
        guard let port = staleLocalhostPort(forVolume: volumeName) else { return false }
        try? unmount(mountpoint: "/Volumes/\(volumeName)")
        killRcloneOnPort(port)
        return true
    }

    /// Parses `/sbin/mount` output for a line like
    /// `http://127.0.0.1:<port>/.../ on /Volumes/<volname> (webdav, ...)` and returns
    /// the port. Returns nil if the volume isn't mounted, or it's mounted from a
    /// non-localhost source (someone else's mount we shouldn't touch).
    private func staleLocalhostPort(forVolume volname: String) -> Int? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/sbin/mount")
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        guard let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return nil
        }
        let suffix = " on /Volumes/\(volname) "
        for line in text.split(separator: "\n") {
            guard line.contains(suffix) else { continue }
            // Expected: "http://127.0.0.1:<port>/<path>/ on /Volumes/<volname> (webdav, ...)"
            guard let prefixRange = line.range(of: "http://127.0.0.1:") else { return nil }
            let after = line[prefixRange.upperBound...]
            // Port runs from here up to the next '/'.
            guard let slash = after.firstIndex(of: "/") else { return nil }
            return Int(after[..<slash])
        }
        return nil
    }

    /// `pgrep -f` for an rclone child whose --addr matches the given port, then SIGTERM.
    /// Per-port matching keeps this safe for users (especially of macsh-lite) who may
    /// have other rclone processes running unrelated to macsh.
    private func killRcloneOnPort(_ port: Int) {
        let pattern = "rclone serve webdav.*--addr 127.0.0.1:\(port)"
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", pattern]
        let out = Pipe()
        pgrep.standardOutput = out
        pgrep.standardError = Pipe()
        do { try pgrep.run() } catch { return }
        pgrep.waitUntilExit()
        guard let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) else {
            return
        }
        for line in text.split(separator: "\n") {
            guard let pid = Int32(line.trimmingCharacters(in: .whitespaces)) else { continue }
            kill(pid, SIGTERM)
        }
    }

    /// Calls `diskutil unmount <mountpoint>`. Falls back to `unmount force` on failure.
    public func unmount(mountpoint: String) throws {
        do {
            try run(
                "/usr/sbin/diskutil",
                args: ["unmount", mountpoint],
                failure: MountError.unmountFailed
            )
        } catch {
            try run(
                "/usr/sbin/diskutil",
                args: ["unmount", "force", mountpoint],
                failure: MountError.unmountFailed
            )
        }
    }

    private func run(_ executable: String, args: [String], failure: (String, Int32) -> MountError) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        p.waitUntilExit()
        if p.terminationStatus != 0 {
            let data = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: data, encoding: .utf8) ?? ""
            throw failure(stderr, p.terminationStatus)
        }
    }
}
