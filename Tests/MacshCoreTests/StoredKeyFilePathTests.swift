import XCTest
@testable import MacshCore

@MainActor
final class StoredKeyFilePathTests: XCTestCase {
    private let keychain = KeychainService(serviceName: "ai.macsh.test")
    private let id = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("macsh-keypath-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? keychain.delete(remoteID: id, kind: .privateKey)
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeManager() -> SessionManager {
        SessionManager(
            store: RemoteStore(directory: dir),
            keychain: keychain,
            mounter: Mounter(),
            logsDir: dir.appendingPathComponent("logs"),
            rcloneBinary: URL(fileURLWithPath: "/usr/bin/true")
        )
    }

    func testReturnsSavedKeyPath() throws {
        try keychain.set(remoteID: id, kind: .privateKey, value: "/Users/me/.ssh/id_ed25519")
        XCTAssertEqual(makeManager().storedKeyFilePath(for: id), "/Users/me/.ssh/id_ed25519")
    }

    func testReturnsNilWhenNothingSaved() {
        XCTAssertNil(makeManager().storedKeyFilePath(for: id))
    }
}
