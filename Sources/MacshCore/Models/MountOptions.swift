import Foundation

/// Per-remote options that apply to every backend: read-only mounts and bandwidth limits.
public enum MountOptions {
    /// rclone `--bwlimit` value: `1M`, `512k`, `0.5M` or `down:up` such as `10M:1M`.
    public static func validateBandwidth(_ value: String) -> String? {
        let v = value.trimmingCharacters(in: .whitespaces)
        if v.isEmpty { return nil }
        let rate = #"\d+(\.\d+)?[bBkKmMgG]?"#
        if v.range(of: "^\(rate)(:\(rate))?$", options: .regularExpression) == nil {
            return "Bandwidth limit must look like 1M, 512k or 10M:1M (download:upload)"
        }
        return nil
    }

    /// Extra `rclone serve` arguments for a remote's options.
    public static func serveArgs(readOnly: Bool, bandwidthLimit: String?) -> [String] {
        var a: [String] = []
        if readOnly { a.append("--read-only") }
        if let bw = bandwidthLimit?.trimmingCharacters(in: .whitespaces), !bw.isEmpty {
            a += ["--bwlimit", bw]
        }
        return a
    }
}
