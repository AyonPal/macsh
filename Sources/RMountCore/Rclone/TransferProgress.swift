import Foundation

/// Only per-file accounting is used: rclone's top-level totals include downloads and past uploads.
public struct RcloneStats: Decodable, Equatable {
    public struct Transfer: Decodable, Equatable {
        public let name: String?
        public let bytes: Int64?
        public let size: Int64?
        public let percentage: Double?
        public let speed: Double?
        public let speedAvg: Double?
        public let eta: Double?

        public init(name: String? = nil, bytes: Int64? = nil, size: Int64? = nil,
                    percentage: Double? = nil, speed: Double? = nil, speedAvg: Double? = nil, eta: Double? = nil) {
            self.name = name; self.bytes = bytes; self.size = size
            self.percentage = percentage; self.speed = speed; self.speedAvg = speedAvg; self.eta = eta
        }

        private enum CodingKeys: String, CodingKey { case name, bytes, size, percentage, speed, speedAvg, eta }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try? c.decode(String.self, forKey: .name)
            bytes = try? c.decode(Int64.self, forKey: .bytes)
            size = try? c.decode(Int64.self, forKey: .size)
            percentage = try? c.decode(Double.self, forKey: .percentage)
            speed = try? c.decode(Double.self, forKey: .speed)
            speedAvg = try? c.decode(Double.self, forKey: .speedAvg)
            eta = try? c.decode(Double.self, forKey: .eta)
        }
    }

    public let transferring: [Transfer]
    public init(transferring: [Transfer] = []) { self.transferring = transferring }
    private enum CodingKeys: String, CodingKey { case transferring }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Decode entries independently so one malformed row does not hide healthy transfers.
        guard var rows = try? c.nestedUnkeyedContainer(forKey: .transferring) else {
            transferring = []; return
        }
        var result: [Transfer] = []
        while !rows.isAtEnd {
            let row = try rows.superDecoder()
            if let transfer = try? Transfer(from: row) { result.append(transfer) }
        }
        transferring = result
    }
}

public struct TransferProgress: Equatable {
    public enum State: String { case queued, uploading, finishing, retrying }
    public let path: String
    public let state: State
    public let bytesDone: Int64?
    public let totalBytes: Int64?
    public let fraction: Double?
    public let speed: Double?
    public let eta: Double?

    static func isSidecar(_ path: String) -> Bool {
        (path as NSString).lastPathComponent.hasPrefix("._")
    }

    static func merge(queue: VFSQueue, stats: RcloneStats?) -> [TransferProgress] {
        let rows = Dictionary(grouping: (stats?.transferring ?? []).filter {
            $0.name.map { !isSidecar($0) } ?? false
        }, by: { $0.name! })
        return queue.queue.filter { !isSidecar($0.name ?? "") }.map { entry in
            // Never match by basename, include downloads, or guess among ambiguous stats rows.
            let matches = rows[entry.name ?? ""] ?? []
            let active = entry.uploading == true && matches.count == 1 ? matches.first : nil
            let total = entry.size.flatMap { $0 >= 0 ? $0 : nil }
                ?? active?.size.flatMap { $0 >= 0 ? $0 : nil }
            let done = active?.bytes.map { min(max(0, $0), total ?? Int64.max) }
            let fraction: Double?
            if let done, let total, total > 0 { fraction = Double(done) / Double(total) }
            else { fraction = active?.percentage.flatMap { $0.isFinite ? min(1, max(0, $0 / 100)) : nil } }
            let speed = (active?.speedAvg ?? active?.speed).flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
            let eta = speed == nil ? nil : active?.eta.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
            let state: State
            if (entry.tries ?? 0) > 1 { state = .retrying }
            else if fraction == 1 { state = .finishing }
            else { state = entry.uploading == true ? .uploading : .queued }
            return TransferProgress(path: entry.name ?? "Unknown file", state: state, bytesDone: done,
                                    totalBytes: total, fraction: fraction, speed: speed, eta: eta)
        }
    }
}

public struct TransferSummary: Equatable {
    public let fileCount: Int
    public let bytesLeft: Int64?
    public let speed: Double?
    public let eta: Double?
    public let text: String

    public init(transfers: [TransferProgress]) {
        fileCount = transfers.count
        let sizes = transfers.compactMap(\.totalBytes)
        let knownProgress = transfers.contains { $0.bytesDone != nil }
        bytesLeft = sizes.count == transfers.count ? transfers.reduce(0) {
            let remaining = max(0, ($1.totalBytes ?? 0) - ($1.bytesDone ?? 0))
            return $0 > Int64.max - remaining ? Int64.max : $0 + remaining
        } : nil
        let rate = transfers.compactMap(\.speed).reduce(0, +)
        speed = rate.isFinite && rate > 0 ? rate : nil
        let estimate = knownProgress && bytesLeft != nil && speed != nil && bytesLeft! > 0
            ? Double(bytesLeft!) / speed! : nil
        eta = estimate.flatMap { $0.isFinite && $0 < Double(Int.max) ? $0 : nil }
        let files = "Uploading \(fileCount) \(fileCount == 1 ? "file" : "files")"
        if let bytesLeft, knownProgress {
            let remaining = ByteCountFormatter.string(fromByteCount: bytesLeft, countStyle: .file)
            text = files + ", \(remaining) left" + (eta.map { " (about \(Self.duration($0)))" } ?? "")
        } else if let bytesLeft {
            text = files + " (\(ByteCountFormatter.string(fromByteCount: bytesLeft, countStyle: .file)))"
        } else { text = files + " (size unknown)" }
    }

    private static func duration(_ seconds: Double) -> String {
        if seconds < 60 { return "\(max(1, Int(seconds.rounded(.up)))) sec" }
        if seconds < 3600 { return "\(Int((seconds / 60).rounded(.up))) min" }
        return "\(Int((seconds / 3600).rounded(.up))) hr"
    }
}
