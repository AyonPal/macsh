import XCTest
@testable import MacshCore

final class RemoteCodableTests: XCTestCase {
    func testSFTPRemoteRoundTrip() throws {
        let r = Remote(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            name: "home-server",
            backend: .sftp(SFTPConfig(
                host: "example.com",
                port: 22,
                user: "alice",
                remotePath: "/data",
                authKind: .password
            )),
            mountProtocol: .webdav,
            autoMount: true
        )
        let data = try JSONEncoder().encode(r)
        let decoded = try JSONDecoder().decode(Remote.self, from: data)
        XCTAssertEqual(decoded, r)
    }
}
