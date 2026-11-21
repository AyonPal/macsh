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

    public var status: UploadStatus {
        let files = queue.filter { entry in
            guard let name = entry.name else { return true }
            return !(name as NSString).lastPathComponent.hasPrefix("._")
        }
        return UploadStatus(queuedCount: files.count,
                            uploadingCount: files.filter { $0.uploading == true }.count,
                            totalBytes: files.reduce(0) { $0 + max(0, $1.size ?? 0) })
    }
}

public struct UploadStatus: Equatable {
    /// All files awaiting completion, including those currently uploading.
    public let queuedCount: Int
    public let uploadingCount: Int
    public let totalBytes: Int64
    public var hasPending: Bool { queuedCount > 0 }

    public init(queuedCount: Int = 0, uploadingCount: Int = 0, totalBytes: Int64 = 0) {
        self.queuedCount = queuedCount
        self.uploadingCount = uploadingCount
        self.totalBytes = totalBytes
    }

    public var menuText: String {
        let bytes = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
        return "Uploading \(queuedCount) \(queuedCount == 1 ? "file" : "files") (\(bytes))"
    }
}

public protocol RcloneControlClient {
    func vfsQueue() async throws -> VFSQueue
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
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw URLError(.badServerResponse)
        }
        return try JSONDecoder().decode(VFSQueue.self, from: data)
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

    init(client: RcloneControlClient, intervals: Intervals = Intervals(), onStatus: @escaping (UploadStatus) -> Void) {
        task = Task { @MainActor in
            var status = UploadStatus()
            while !Task.isCancelled {
                do {
                    status = try await client.vfsQueue().status
                    guard !Task.isCancelled else { return }
                    onStatus(status)
                } catch {
                    // Keep the last known queue when RC is temporarily unreachable.
                    if Task.isCancelled { return }
                }
                do { try await Task.sleep(nanoseconds: UInt64(intervals.delay(for: status) * 1_000_000_000)) }
                catch { return }
            }
        }
    }

    func stop() { task?.cancel(); task = nil }
    deinit { task?.cancel() }
}
