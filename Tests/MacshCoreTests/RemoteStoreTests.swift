import XCTest
@testable import MacshCore

final class RemoteStoreTests: XCTestCase {
    var tmpDir: URL!

    override func setUpWithError() throws {
        tmpDir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("macsh-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
    }

    func testEmptyOnFreshDirectory() throws {
        let store = RemoteStore(directory: tmpDir)
        XCTAssertEqual(try store.load(), [])
    }

    func testSaveThenLoad() throws {
        let store = RemoteStore(directory: tmpDir)
        let r = Remote(
            id: UUID(),
            name: "test",
            backend: .sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .password)),
            mountProtocol: .webdav,
            autoMount: false
        )
        try store.save([r])
        XCTAssertEqual(try store.load(), [r])
    }

    func testCorruptFileThrows() throws {
        let store = RemoteStore(directory: tmpDir)
        try "not json".write(to: tmpDir.appendingPathComponent("remotes.json"), atomically: true, encoding: .utf8)
        XCTAssertThrowsError(try store.load())
    }
}
