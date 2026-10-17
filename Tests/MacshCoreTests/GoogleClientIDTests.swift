import XCTest
@testable import MacshCore

final class GoogleClientIDTests: XCTestCase {
    private let drive = BackendDescriptor.googleDrive

    func testSharedClientIDIsDetectedWhenBlank() {
        XCTAssertTrue(drive.usesSharedClientID(values: [:]))
        XCTAssertTrue(drive.usesSharedClientID(values: ["client_id": "   "]))
        XCTAssertFalse(drive.usesSharedClientID(values: ["client_id": "123.apps.googleusercontent.com"]))
    }

    func testBackendsWithoutOAuthNeverReportSharedClient() {
        XCTAssertFalse(BackendDescriptor.webdav.usesSharedClientID(values: [:]))
        XCTAssertFalse(BackendDescriptor.smb.usesSharedClientID(values: [:]))
    }

    func testHelpLinkOnlyForDrive() {
        XCTAssertEqual(drive.ownClientIDHelpURL?.host, "rclone.org")
        XCTAssertNil(BackendDescriptor.webdav.ownClientIDHelpURL)
    }

    func testChangingClientIDWithoutSigningInAgainIsRejected() {
        let original = ["client_id": ""]
        let problem = drive.clientChangeNeedsSignIn(original: original, values: ["client_id": "new.apps.googleusercontent.com"], isEditing: true)
        XCTAssertNotNil(problem)
        XCTAssertTrue(problem?.contains("Sign in again") == true)
    }

    func testSigningInAgainClearsTheProblem() {
        let values = ["client_id": "new.apps.googleusercontent.com", "token": "{\"access_token\":\"x\"}"]
        XCTAssertNil(drive.clientChangeNeedsSignIn(original: ["client_id": ""], values: values, isEditing: true))
    }

    func testUnchangedClientIDIsFine() {
        let same = ["client_id": "a.apps.googleusercontent.com"]
        XCTAssertNil(drive.clientChangeNeedsSignIn(original: same, values: same, isEditing: true))
    }

    func testNewClientSecretAloneNeedsSignIn() {
        let v = ["client_id": "a", "client_secret": "s3cret"]
        XCTAssertNotNil(drive.clientChangeNeedsSignIn(original: ["client_id": "a"], values: v, isEditing: true))
    }

    func testAddingANewRemoteIsNeverBlockedHere() {
        // On add the token is required by the normal validation instead.
        XCTAssertNil(drive.clientChangeNeedsSignIn(original: [:], values: ["client_id": "x"], isEditing: false))
    }
}
