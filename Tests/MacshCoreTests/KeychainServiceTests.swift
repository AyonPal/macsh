import XCTest
@testable import MacshCore

final class KeychainServiceTests: XCTestCase {
    let svc = KeychainService(serviceName: "ai.macsh.test")
    let id = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!

    override func tearDown() {
        try? svc.delete(remoteID: id, kind: .password)
        try? svc.delete(remoteID: id, kind: .localServePassword)
    }

    func testRoundTrip() throws {
        try svc.set(remoteID: id, kind: .password, value: "hunter2")
        XCTAssertEqual(try svc.get(remoteID: id, kind: .password), "hunter2")
    }

    func testOverwrite() throws {
        try svc.set(remoteID: id, kind: .password, value: "first")
        try svc.set(remoteID: id, kind: .password, value: "second")
        XCTAssertEqual(try svc.get(remoteID: id, kind: .password), "second")
    }

    func testGetMissingReturnsNil() throws {
        XCTAssertNil(try svc.get(remoteID: id, kind: .localServePassword))
    }

    func testDelete() throws {
        try svc.set(remoteID: id, kind: .password, value: "x")
        try svc.delete(remoteID: id, kind: .password)
        XCTAssertNil(try svc.get(remoteID: id, kind: .password))
    }
}
