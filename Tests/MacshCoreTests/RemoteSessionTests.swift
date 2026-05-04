import XCTest
@testable import MacshCore

final class RemoteSessionTests: XCTestCase {
    func testInitialStateIsIdle() {
        let r = makeRemote()
        let session = RemoteSession(remote: r)
        XCTAssertEqual(session.status, .idle)
    }

    func testTransitionToStartingThenMounted() {
        let session = RemoteSession(remote: makeRemote())
        session.transition(to: .starting)
        XCTAssertEqual(session.status, .starting)
        session.transition(to: .mounted(at: "/Volumes/x"))
        if case .mounted(let path) = session.status {
            XCTAssertEqual(path, "/Volumes/x")
        } else {
            XCTFail("expected mounted")
        }
    }

    func testTransitionToFailedRecordsReason() {
        let session = RemoteSession(remote: makeRemote())
        session.transition(to: .failed(reason: "boom"))
        XCTAssertEqual(session.status, .failed(reason: "boom"))
    }

    private func makeRemote() -> Remote {
        Remote(
            id: UUID(),
            name: "x",
            backend: .sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .password)),
            mountProtocol: .webdav,
            autoMount: false
        )
    }
}
