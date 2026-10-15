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

    public init(cacheMode: VFSCacheMode, readAhead: String, bufferSize: String, cacheMaxSize: String, dirCacheTime: String, writeBack: String = "") {
        self.cacheMode = cacheMode
        self.readAhead = readAhead
        self.bufferSize = bufferSize
        self.cacheMaxSize = cacheMaxSize
        self.dirCacheTime = dirCacheTime
        self.writeBack = writeBack
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
    }

    /// WebDAV keeps the original conservative settings. NFS issues many small reads, so
    /// it needs a read cache + read-ahead (measured 2.5 MB/s with `writes` vs ~17 MB/s).
    public static func defaults(for proto: MountProtocol) -> TransferTuning {
        switch proto {
        case .webdav:
            return TransferTuning(cacheMode: .writes, readAhead: "", bufferSize: "", cacheMaxSize: "", dirCacheTime: "10s")
        case .nfs:
            return TransferTuning(cacheMode: .full, readAhead: "128M", bufferSize: "32M", cacheMaxSize: "5G", dirCacheTime: "10s", writeBack: "1s")
        }
    }

    /// Returns a message if a field isn't a valid rclone size/duration.
    public func validate() -> String? {
        for (label, v) in [("Read-ahead", readAhead), ("Buffer size", bufferSize), ("Max cache size", cacheMaxSize)]
        where !v.isEmpty && v.range(of: #"^\d+[kKmMgGtT]?$"#, options: .regularExpression) == nil {
            return "\(label) must look like 128M or 5G"
        }
        if !dirCacheTime.isEmpty, dirCacheTime.range(of: #"^\d+(ms|s|m|h)$"#, options: .regularExpression) == nil {
            return "Directory cache time must look like 10s or 5m"
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
        if liveUpdates {
            if !dirCacheTime.isEmpty { a += ["--dir-cache-time", dirCacheTime] }
            a.append("--vfs-fast-fingerprint")
        }
        return a
    }
}
