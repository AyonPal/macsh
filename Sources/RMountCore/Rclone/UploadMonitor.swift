import Foundation

public struct VFSQueue: Decodable, Equatable {
    public struct Entry: Decodable, Equatable {
        public let name: String?
        public let id: UInt64?
        public let size: Int64?
        public let uploading: Bool?
        public let expiry: Double?
        public let tries: Int?
        public let delay: Double?

        public init(name: String? = nil, id: UInt64? = nil, size: Int64? = nil, uploading: Bool? = nil,
                    expiry: Double? = nil, tries: Int? = nil, delay: Double? = nil) {
            self.name = name
            self.id = id
            self.size = size
            self.uploading = uploading
            self.expiry = expiry
            self.tries = tries
            self.delay = delay
        }
    }

    public let queue: [Entry]

    public init(queue: [Entry] = []) { self.queue = queue }

    private enum CodingKeys: String, CodingKey { case queue }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        queue = try values.decodeIfPresent([Entry].self, forKey: .queue) ?? []
    }

    public var status: UploadStatus { status(stats: nil) }

    public func status(stats: RcloneStats?, isStale: Bool = false) -> UploadStatus {
        let transfers = TransferProgress.merge(queue: self, stats: stats)
        let total = transfers.compactMap(\.totalBytes).reduce(Int64(0)) {
            $0 > Int64.max - $1 ? Int64.max : $0 + $1
        }
        return UploadStatus(queuedCount: transfers.count,
                            uploadingCount: queue.filter { !TransferProgress.isSidecar($0.name ?? "") && $0.uploading == true }.count,
                            totalBytes: total, transfers: transfers, isStale: isStale)
    }
}

public struct UploadStatus: Equatable {
    /// All files awaiting completion, including those currently uploading.
    public let queuedCount: Int
    public let uploadingCount: Int
    public let totalBytes: Int64
    public let transfers: [TransferProgress]
    public let isStale: Bool
    public var hasPending: Bool { queuedCount > 0 }
    public var summary: TransferSummary { TransferSummary(transfers: transfers) }

    public init(queuedCount: Int = 0, uploadingCount: Int = 0, totalBytes: Int64 = 0,
                transfers: [TransferProgress] = [], isStale: Bool = false) {
        self.queuedCount = queuedCount
        self.uploadingCount = uploadingCount
        self.totalBytes = totalBytes
        self.transfers = transfers
        self.isStale = isStale
    }

    public var menuText: String {
        if !transfers.isEmpty { return summary.text }
        let bytes = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "Uploading \(queuedCount) \(queuedCount == 1 ? "file" : "files") (\(bytes))"
    }
}

public protocol RcloneControlClient {
    func vfsQueue() async throws -> VFSQueue
    func coreStats() async throws -> RcloneStats
}

public extension RcloneControlClient {
    func coreStats() async throws -> RcloneStats { throw URLError(.unsupportedURL) }
}

public struct URLSessionRcloneControlClient: RcloneControlClient {
    private let request: URLRequest
    private let session: URLSession

    public init(port: Int, user: String, password: String, session: URLSession = .shared) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/vfs/queue")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 3
        let auth = Data("\(user):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        self.request = request
        self.session = session
    }

    public func vfsQueue() async throws -> VFSQueue {
        try await perform(request, as: VFSQueue.self)
    }

    public func coreStats() async throws -> RcloneStats {
        var statsRequest = request
        statsRequest.url = request.url?.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("core/stats")
        return try await perform(statsRequest, as: RcloneStats.self)
    }

    private func perform<T: Decodable>(_ request: URLRequest, as type: T.Type) async throws -> T {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(type, from: data)
    }
}

@MainActor
final class UploadMonitor {
    struct Intervals {
        var pending: TimeInterval = 2.5
        var idle: TimeInterval = 15
        func delay(for status: UploadStatus) -> TimeInterval { status.hasPending ? pending : idle }
    }

    private var task: Task<Void, Never>?
    private var inFlight: Task<UploadStatus, Never>?
    private let client: RcloneControlClient
    private let onStatus: (UploadStatus) -> Void
    private var lastQueue = VFSQueue()
    private var failedPolls = 0
    private var stopped = false

    init(client: RcloneControlClient, intervals: Intervals = Intervals(), onStatus: @escaping (UploadStatus) -> Void) {
        self.client = client
        self.onStatus = onStatus
        task = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let status = await self?.refresh() else { return }
                do { try await Task.sleep(nanoseconds: UInt64(intervals.delay(for: status) * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    /// Explicit safety refreshes and background polling share one serialized sample.
    @discardableResult
    func refresh() async -> UploadStatus {
        if let inFlight { return await inFlight.value }
        if stopped { return lastQueue.status(stats: nil, isStale: failedPolls >= 2) }
        let sample = Task { @MainActor in
            var queueSucceeded = false
            var stats: RcloneStats?
            do { self.lastQueue = try await self.client.vfsQueue(); queueSucceeded = true } catch {}
            do { stats = try await self.client.coreStats() } catch {}
            self.failedPolls = queueSucceeded && stats != nil ? 0 : self.failedPolls + 1
            // Accounting from a different queue sample must never imply upload completion.
            let status = self.lastQueue.status(stats: queueSucceeded ? stats : nil, isStale: self.failedPolls >= 2)
            self.inFlight = nil
            if !self.stopped && !Task.isCancelled { self.onStatus(status) }
            return status
        }
        inFlight = sample
        return await sample.value
    }

    func stop() {
        stopped = true
        task?.cancel(); task = nil
        inFlight?.cancel(); inFlight = nil
    }
    deinit { task?.cancel(); inFlight?.cancel() }
}
