import XCTest
import Darwin
@testable import RMountCore

/// Exercises only private localhost servers and temporary storage; no filesystem mount is made.
final class UploadQueueIntegrationTests: XCTestCase {
    private func fixture() throws -> (RcloneProcess, URL) {
        let path = ProcessInfo.processInfo.environment["RMOUNT_IT_RCLONE"]
            ?? "/Applications/rmount.app/Contents/Resources/rclone"
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw XCTSkip("No real rclone available for the upload queue test")
        }
        try requireLocalhost()
        let dir = try makeTempDir()
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("backend"), withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return (RcloneProcess(binary: URL(fileURLWithPath: path), logFile: dir.appendingPathComponent("rclone.log")), dir)
    }

    private func requireLocalhost() throws {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw XCTSkip("Localhost sockets unavailable") }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0, errno == EPERM || errno == EACCES {
            throw XCTSkip("Sandbox does not permit binding private localhost test servers")
        }
        XCTAssertEqual(result, 0, "Could not bind a private localhost test server")
    }

    private func manage(_ spawned: RcloneProcess.Spawned) {
        addTeardownBlock {
            // Only the process this test started is ever stopped.
            if spawned.process.isRunning {
                spawned.process.terminate()
                spawned.process.waitUntilExit()
            }
            try? FileManager.default.removeItem(at: spawned.configURL.deletingLastPathComponent())
        }
    }

    private func ready(_ client: URLSessionRcloneControlClient, spawned: RcloneProcess.Spawned) async throws -> VFSQueue {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let queue = try? await client.vfsQueue() { return queue }
            guard spawned.process.isRunning else {
                XCTFail("Private rclone server exited before its control interface was ready")
                throw URLError(.cannotConnectToHost)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return try await client.vfsQueue()
    }

    func testWebDAVWriteBackAppearsInQueueAndReachesBackend() async throws {
        let (runner, dir) = try fixture()
        let backend = dir.appendingPathComponent("backend")
        var tuning = TransferTuning.defaults(for: .webdav)
        tuning.cacheMode = .full
        tuning.writeBack = "20s"
        let spawned = try runner.spawnWebDAVServe(
            remoteName: "r", remotePath: backend.path, configText: "[r]\ntype = local\n",
            baseurl: "/", liveUpdates: false, tuning: tuning,
            extraArgs: ["--cache-dir", dir.appendingPathComponent("cache").path])
        manage(spawned)
        let client = URLSessionRcloneControlClient(port: spawned.rcPort, user: spawned.rcUser, password: spawned.rcPassword)
        let initial = try await ready(client, spawned: spawned)
        XCTAssertFalse(initial.status.hasPending)

        let payload = Data("private upload queue test".utf8)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(spawned.port)/pending.txt")!)
        request.httpMethod = "PUT"
        request.httpBody = payload
        request.timeoutInterval = 5
        let auth = Data("\(spawned.user):\(spawned.password)".utf8).base64EncodedString()
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await URLSession.shared.data(for: request)
        XCTAssertTrue((200..<300).contains(try XCTUnwrap(response as? HTTPURLResponse).statusCode))

        var queueRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(spawned.rcPort)/vfs/queue")!)
        queueRequest.httpMethod = "POST"
        queueRequest.timeoutInterval = 3
        let rcAuth = Data("\(spawned.rcUser):\(spawned.rcPassword)".utf8).base64EncodedString()
        queueRequest.setValue("Basic \(rcAuth)", forHTTPHeaderField: "Authorization")
        let (queueData, _) = try await URLSession.shared.data(for: queueRequest)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: queueData) as? [String: Any])
        let entries = try XCTUnwrap(object["queue"] as? [[String: Any]])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry["name"] as? String, "pending.txt")
        for key in ["id", "size", "expiry", "tries", "delay"] {
            XCTAssertNotNil(entry[key] as? NSNumber, "Expected numeric \(key) in rclone's queue response")
        }
        XCTAssertEqual(entry["uploading"] as? Bool, false)

        let pending = try await client.vfsQueue()
        XCTAssertEqual(pending.queue.count, 1)
        XCTAssertEqual(pending.status.queuedCount, 1)
        XCTAssertEqual(pending.status.totalBytes, Int64(payload.count))
        XCTAssertTrue(pending.status.hasPending)
        XCTAssertFalse(FileManager.default.fileExists(atPath: backend.appendingPathComponent("pending.txt").path))

        var drained = false
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline {
            let queue = try await client.vfsQueue()
            if !queue.status.hasPending {
                drained = true
                break
            }
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        XCTAssertTrue(drained, "The write-back queue did not drain")
        XCTAssertEqual(try Data(contentsOf: backend.appendingPathComponent("pending.txt")), payload)
    }

    func testNFSServeExposesTheSameQueueWithoutMounting() async throws {
        let (runner, dir) = try fixture()
        let spawned = try runner.spawnNFSServe(
            remoteName: "r", remotePath: dir.appendingPathComponent("backend").path,
            configText: "[r]\ntype = local\n", liveUpdates: false,
            extraArgs: ["--cache-dir", dir.appendingPathComponent("cache").path])
        manage(spawned)
        let client = URLSessionRcloneControlClient(port: spawned.rcPort, user: spawned.rcUser, password: spawned.rcPassword)
        let queue = try await ready(client, spawned: spawned)
        XCTAssertTrue(queue.queue.isEmpty)
        XCTAssertFalse(queue.status.hasPending)
    }
}
