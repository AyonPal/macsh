import XCTest
@testable import RMountCore

@MainActor
private func waitUntil(
    timeout: TimeInterval = 5,
    pollInterval: TimeInterval = 0.01,
    _ condition: () async -> Bool
) async throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try await Task.sleep(nanoseconds: UInt64(pollInterval * 1_000_000_000))
    }
    return await condition()
}

private final class ControlURLProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (code, data) = try Self.handler!(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}

private actor FakeControlClient: RcloneControlClient {
    var calls = 0
    var queue: VFSQueue
    var fails = false
    init(_ queue: VFSQueue = VFSQueue()) { self.queue = queue }
    func vfsQueue() async throws -> VFSQueue {
        calls += 1
        if fails { throw URLError(.cannotConnectToHost) }
        return queue
    }
    func setQueue(_ queue: VFSQueue) { self.queue = queue }
    func setFails() { fails = true }
}

final class UploadMonitorTests: XCTestCase {
    func testQueueParsesEmptyMissingAndNullQueues() throws {
        for json in ["{}", "{\"queue\":null}", "{\"queue\":[]}"] {
            let queue = try JSONDecoder().decode(VFSQueue.self, from: Data(json.utf8))
            XCTAssertEqual(queue, VFSQueue())
            XCTAssertEqual(queue.status, UploadStatus())
            XCTAssertFalse(queue.status.hasPending)
        }
    }

    func testQueueParsesEntriesAndIgnoresUnknownMetadata() throws {
        let json = """
        {"queue":[{"name":"a","id":1,"size":1200,"expiry":20.5,"tries":0,"delay":20,"uploading":true},{"name":"b","size":300},{},{"size":-1,"uploading":false}]}
        """
        let queue = try JSONDecoder().decode(VFSQueue.self, from: Data(json.utf8))
        XCTAssertEqual(queue.queue[0], VFSQueue.Entry(name: "a", id: 1, size: 1200, uploading: true, expiry: 20.5, tries: 0, delay: 20))
        XCTAssertNil(queue.queue[2].name)
        XCTAssertEqual(queue.status, UploadStatus(queuedCount: 4, uploadingCount: 1, totalBytes: 1500))
        XCTAssertTrue(queue.status.hasPending)
        XCTAssertTrue(queue.status.menuText.hasPrefix("Uploading 4 files ("))
        XCTAssertTrue(UploadStatus(queuedCount: 1).menuText.hasPrefix("Uploading 1 file ("))
    }

    func testQueueStatusExcludesAppleDoubleSidecars() {
        let queue = VFSQueue(queue: [
            .init(name: "big1.bin", size: 1000, uploading: true),
            .init(name: "._big1.bin", size: 4096, uploading: true),
            .init(name: "big2.bin", size: 2000, uploading: false),
            .init(name: "._big2.bin", size: 4096, uploading: false),
            .init(size: 500, uploading: true)
        ])
        XCTAssertEqual(queue.status, UploadStatus(queuedCount: 3, uploadingCount: 2, totalBytes: 3500))
        XCTAssertTrue(queue.status.hasPending)
    }

    func testQueueStatusWithOnlyAppleDoubleSidecarsHasNoPendingUploads() {
        let queue = VFSQueue(queue: [
            .init(name: "._big1.bin", size: 4096, uploading: true),
            .init(name: "._big2.bin", size: 4096, uploading: false)
        ])
        XCTAssertEqual(queue.status, UploadStatus())
        XCTAssertFalse(queue.status.hasPending)
    }

    func testQueueStatusExcludesNestedAppleDoubleSidecars() {
        let queue = VFSQueue(queue: [.init(name: "dir/._x", size: 4096, uploading: true)])
        XCTAssertEqual(queue.status, UploadStatus())
        XCTAssertFalse(queue.status.hasPending)
    }

    func testQueueStatusCountsAppleDoubleMarkerWithinNames() {
        let queue = VFSQueue(queue: [
            .init(name: "file._part.bin", size: 1000, uploading: true),
            .init(name: "._dir/real.bin", size: 2000, uploading: false)
        ])
        XCTAssertEqual(queue.status, UploadStatus(queuedCount: 2, uploadingCount: 1, totalBytes: 3000))
        XCTAssertTrue(queue.status.hasPending)
    }

    func testClientPostsWithBasicAuthAndTimeout() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [ControlURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel(); ControlURLProtocol.handler = nil }
        ControlURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:43210/vfs/queue")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.timeoutInterval, 3)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("user:secret".utf8).base64EncodedString())
            return (200, Data("{\"queue\":[{\"name\":\"a\"}]}".utf8))
        }
        let client = URLSessionRcloneControlClient(port: 43210, user: "user", password: "secret", session: session)
        let queue = try await client.vfsQueue()
        XCTAssertEqual(queue.status.queuedCount, 1)
        ControlURLProtocol.handler = { _ in (401, Data()) }
        do { _ = try await client.vfsQueue(); XCTFail("Expected rejected response") }
        catch { XCTAssertEqual((error as? URLError)?.code, .badServerResponse) }
        ControlURLProtocol.handler = { _ in (200, Data("invalid".utf8)) }
        do { _ = try await client.vfsQueue(); XCTFail("Expected decoding error") }
        catch { XCTAssertTrue(error is DecodingError) }
    }

    @MainActor
    func testPollingAdaptsRetainsStatusOnFailureAndStops() async throws {
        let pending = VFSQueue(queue: [.init(size: 5)])
        let client = FakeControlClient(pending)
        var statuses: [UploadStatus] = []
        let intervals = UploadMonitor.Intervals(pending: 0.01, idle: 0.15)
        XCTAssertEqual(UploadMonitor.Intervals().delay(for: pending.status), 2.5)
        XCTAssertEqual(UploadMonitor.Intervals().delay(for: UploadStatus()), 15)
        let monitor = UploadMonitor(client: client, intervals: intervals) { statuses.append($0) }
        let sawPendingPolls = try await waitUntil {
            await client.calls > 2
        }
        XCTAssertTrue(sawPendingPolls, "Expected multiple polls while uploads were pending")
        let pendingCalls = await client.calls
        XCTAssertGreaterThan(pendingCalls, 2)
        await client.setQueue(VFSQueue())
        let sawIdleStatus = try await waitUntil {
            statuses.last == UploadStatus()
        }
        XCTAssertTrue(sawIdleStatus, "Expected the monitor to report an idle queue")
        let idleCalls = await client.calls
        try await Task.sleep(nanoseconds: 300_000_000)
        let stillIdleCalls = await client.calls
        XCTAssertLessThanOrEqual(stillIdleCalls - idleCalls, 2, "Idle polling should be near the configured 0.15 second interval")
        await client.setFails()
        let sawFailedPoll = try await waitUntil {
            await client.calls > stillIdleCalls
        }
        XCTAssertTrue(sawFailedPoll, "Expected another poll after the client began failing")
        XCTAssertEqual(statuses.last, UploadStatus())
        monitor.stop()
        let stoppedCalls = await client.calls
        try await Task.sleep(nanoseconds: 300_000_000)
        let finalCalls = await client.calls
        XCTAssertEqual(stoppedCalls, finalCalls)
    }

    @MainActor
    func testMonitorDeinitCancelsPolling() async throws {
        let client = FakeControlClient()
        var monitor: UploadMonitor? = UploadMonitor(client: client, intervals: .init(pending: 0.01, idle: 0.01)) { _ in }
        XCTAssertNotNil(monitor)
        try await Task.sleep(nanoseconds: 25_000_000)
        monitor = nil
        let stopped = await client.calls
        try await Task.sleep(nanoseconds: 35_000_000)
        let final = await client.calls
        XCTAssertEqual(stopped, final)
    }

    func testGuardWarnsOnlyForPendingAndUsesActionText() throws {
        XCTAssertNil(UploadGuard.warning(for: .quit, uploads: []))
        XCTAssertNil(UploadGuard.warning(for: .unmount, uploads: [("idle", UploadStatus())]))
        let uploads = [(remoteName: "Drive", status: UploadStatus(queuedCount: 1))]
        let quit = try XCTUnwrap(UploadGuard.warning(for: .quit, uploads: uploads))
        XCTAssertEqual(quit.messageText, "1 file is still uploading to Drive. Quit anyway?")
        XCTAssertEqual(quit.confirmButtonTitle, "Quit Anyway")
        XCTAssertEqual(quit.waitButtonTitle, "Wait")
        XCTAssertFalse(quit.informativeText.isEmpty)
        let unmount = try XCTUnwrap(UploadGuard.warning(for: .unmount, uploads: uploads))
        XCTAssertEqual(unmount.messageText, "1 file is still uploading to Drive. Unmount anyway?")
        XCTAssertEqual(unmount.confirmButtonTitle, "Unmount Anyway")
        let update = try XCTUnwrap(UploadGuard.warning(for: .installUpdate, uploads: uploads + [("S3", UploadStatus(queuedCount: 2)), ("idle", UploadStatus())]))
        XCTAssertEqual(update.messageText, "3 files are still uploading to Drive, S3. Install update anyway?")
        XCTAssertEqual(update.confirmButtonTitle, "Install Update Anyway")
    }
}
