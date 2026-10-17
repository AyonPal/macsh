import Foundation

/// rclone VFS cache mode (`--vfs-cache-mode`).
public enum VFSCacheMode: String, Codable, CaseIterable, Equatable {
    case off, minimal, writes, full
}

/// Per-remote performance options passed to `rclone serve`. A `nil` tuning on a
/// `Remote` means "use `defaults(for:)`".
public struct TransferTuning: Codable, Equatable {
    public var cacheMode: VFSCacheMode
    /// rclone size strings such as `128M`, `5G`. Empty = leave at rclone's default.
    public var readAhead: String
    public var bufferSize: String
    public var cacheMaxSize: String
    /// rclone duration such as `10s`. Only used when live updates are on.
    public var dirCacheTime: String
    /// Delay before a written file is uploaded (`--vfs-write-back`). Empty = rclone's 5s.
    /// `0` is rejected: it makes every write synchronous and is ~100x slower.
    public var writeBack: String
    /// Read the whole folder tree into the directory cache in the background right after
    /// mounting (`--vfs-refresh`), so entering a folder doesn't wait for the cloud API.
    public var prefetchFolders: Bool
    /// How often rclone asks the remote for changes (`--poll-interval`); lets a long
    /// `dirCacheTime` stay fresh on remotes with change notifications. Empty = rclone's 1m.
    public var pollInterval: String
    /// `--drive-acknowledge-abuse`: allow downloading files Google flags as malware/abuse.
    /// Off by default; only meaningful for Google Drive.
    public var acknowledgeAbuse: Bool
    /// Parallel ranged downloads per file (`--vfs-read-chunk-streams`). 0 = rclone's single
    /// stream (the default). Measured on Google Drive: 4 x 32M changed nothing (fresh 50 MB
    /// files 12-16 MB/s either way, slow archives 1.2-2.5 vs 1.4-1.6 MB/s), so it is opt-in.
    public var readChunkStreams: Int
    /// Size of each parallel chunk (`--vfs-read-chunk-size`). Empty = rclone's 128M.
    public var readChunkSize: String

    public init(cacheMode: VFSCacheMode, readAhead: String, bufferSize: String, cacheMaxSize: String, dirCacheTime: String, writeBack: String = "",
                prefetchFolders: Bool = false, pollInterval: String = "", acknowledgeAbuse: Bool = false,
                readChunkStreams: Int = 0, readChunkSize: String = "") {
        self.cacheMode = cacheMode
        self.readAhead = readAhead
        self.bufferSize = bufferSize
        self.cacheMaxSize = cacheMaxSize
        self.dirCacheTime = dirCacheTime
        self.writeBack = writeBack
        self.prefetchFolders = prefetchFolders
        self.pollInterval = pollInterval
        self.acknowledgeAbuse = acknowledgeAbuse
        self.readChunkStreams = readChunkStreams
        self.readChunkSize = readChunkSize
    }

    // Remotes saved before `writeBack` existed decode with it empty.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        cacheMode = try c.decode(VFSCacheMode.self, forKey: .cacheMode)
        readAhead = try c.decode(String.self, forKey: .readAhead)
        bufferSize = try c.decode(String.self, forKey: .bufferSize)
        cacheMaxSize = try c.decode(String.self, forKey: .cacheMaxSize)
        dirCacheTime = try c.decode(String.self, forKey: .dirCacheTime)
        writeBack = try c.decodeIfPresent(String.self, forKey: .writeBack) ?? ""
        prefetchFolders = try c.decodeIfPresent(Bool.self, forKey: .prefetchFolders) ?? false
        pollInterval = try c.decodeIfPresent(String.self, forKey: .pollInterval) ?? ""
        acknowledgeAbuse = try c.decodeIfPresent(Bool.self, forKey: .acknowledgeAbuse) ?? false
        readChunkStreams = try c.decodeIfPresent(Int.self, forKey: .readChunkStreams) ?? 0
        readChunkSize = try c.decodeIfPresent(String.self, forKey: .readChunkSize) ?? ""
    }

    /// WebDAV keeps the original conservative settings. NFS issues many small reads, so
    /// it needs a read cache + read-ahead (measured 2.5 MB/s with `writes` vs ~17 MB/s).
    ///
    /// Cloud remotes that report changes (`pollingBackends`) get a long directory cache kept
    /// fresh by polling, and the folder tree is prefetched: re-listing every 10s through the
    /// cloud API made every folder visit slow and starved the mount.
    public static func defaults(for proto: MountProtocol, backendType: String? = nil) -> TransferTuning {
        var t: TransferTuning
        switch proto {
        case .webdav:
            t = TransferTuning(cacheMode: .writes, readAhead: "", bufferSize: "", cacheMaxSize: "", dirCacheTime: "10s")
        case .nfs:
            t = TransferTuning(cacheMode: .full, readAhead: "128M", bufferSize: "32M", cacheMaxSize: "5G", dirCacheTime: "10s", writeBack: "1s")
        }
        if let backendType, pollingBackends.contains(backendType) {
            t.dirCacheTime = "1h"
            t.pollInterval = "30s"
            t.prefetchFolders = true
        }
        return t
    }

    /// rclone backend types that notify about remote changes, so `--poll-interval` works.
    public static let pollingBackends: Set<String> = ["drive", "onedrive", "dropbox", "box"]

    /// Seconds in an rclone duration like `30s`, `5m`, `1h`, `500ms`; nil if malformed.
    static func seconds(of duration: String) -> Double? {
        guard duration.range(of: #"^\d+(ms|s|m|h)$"#, options: .regularExpression) != nil,
              let n = Double(duration.prefix { $0.isNumber }) else { return nil }
        if duration.hasSuffix("ms") { return n / 1000 }
        if duration.hasSuffix("s") { return n }
        if duration.hasSuffix("m") { return n * 60 }
        return n * 3600
    }

    /// Returns a message if a field isn't a valid rclone size/duration.
    public func validate() -> String? {
        if !(0...32).contains(readChunkStreams) { return "Parallel read streams must be 0 to 32" }
        for (label, v) in [("Read-ahead", readAhead), ("Buffer size", bufferSize), ("Max cache size", cacheMaxSize), ("Read chunk size", readChunkSize)]
        where !v.isEmpty && v.range(of: #"^\d+[kKmMgGtT]?$"#, options: .regularExpression) == nil {
            return "\(label) must look like 128M or 5G"
        }
        if !dirCacheTime.isEmpty, dirCacheTime.range(of: #"^\d+(ms|s|m|h)$"#, options: .regularExpression) == nil {
            return "Directory cache time must look like 10s or 5m"
        }
        if !pollInterval.isEmpty {
            guard let poll = Self.seconds(of: pollInterval), poll > 0 else {
                return "Poll interval must look like 30s or 1m"
            }
            if let cache = Self.seconds(of: dirCacheTime), poll >= cache {
                return "Poll interval must be shorter than the directory cache time"
            }
        }
        if !writeBack.isEmpty {
            guard writeBack.range(of: #"^\d+(ms|s|m|h)$"#, options: .regularExpression) != nil,
                  let n = Int(writeBack.prefix { $0.isNumber }), n > 0 else {
                return "Write-back delay must look like 1s or 5s (not 0)"
            }
        }
        return nil
    }

    func serveArgs(liveUpdates: Bool) -> [String] {
        var a = ["--vfs-cache-mode", cacheMode.rawValue]
        if !cacheMaxSize.isEmpty { a += ["--vfs-cache-max-size", cacheMaxSize] }
        if !readAhead.isEmpty { a += ["--vfs-read-ahead", readAhead] }
        if !bufferSize.isEmpty { a += ["--buffer-size", bufferSize] }
        if !writeBack.isEmpty { a += ["--vfs-write-back", writeBack] }
        if readChunkStreams > 0 { a += ["--vfs-read-chunk-streams", String(readChunkStreams)] }
        if !readChunkSize.isEmpty { a += ["--vfs-read-chunk-size", readChunkSize] }
        if prefetchFolders { a.append("--vfs-refresh") }
        if !pollInterval.isEmpty { a += ["--poll-interval", pollInterval] }
        if acknowledgeAbuse { a.append("--drive-acknowledge-abuse") }
        if liveUpdates {
            if !dirCacheTime.isEmpty { a += ["--dir-cache-time", dirCacheTime] }
            a.append("--vfs-fast-fingerprint")
        }
        return a
    }
}
