import XCTest
@testable import MacshCore

final class MountURLTests: XCTestCase {
    func testBasicURL() {
        let url = MountURL.webdav(host: "127.0.0.1", port: 8421, user: "u", password: "p")
        XCTAssertEqual(url, "http://u:p@127.0.0.1:8421/")
    }

    func testPasswordPercentEncoded() {
        let url = MountURL.webdav(host: "127.0.0.1", port: 8421, user: "u", password: "a@b:c/d")
        XCTAssertEqual(url, "http://u:a%40b%3Ac%2Fd@127.0.0.1:8421/")
    }
}
