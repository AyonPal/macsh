import XCTest
@testable import MacshCore

final class BackendTests: XCTestCase {
    func testRcloneProviderMapping() {
        XCTAssertEqual(S3Provider.aws.rcloneProvider, "AWS")
        XCTAssertEqual(S3Provider.cloudflareR2.rcloneProvider, "Cloudflare")
        XCTAssertEqual(S3Provider.wasabi.rcloneProvider, "Wasabi")
        XCTAssertEqual(S3Provider.minio.rcloneProvider, "Minio")
        XCTAssertEqual(S3Provider.digitalOcean.rcloneProvider, "DigitalOcean")
        XCTAssertEqual(S3Provider.backblazeB2.rcloneProvider, "Other")
        XCTAssertEqual(S3Provider.other.rcloneProvider, "Other")
    }

    func testEveryProviderHasDisplayName() {
        for p in S3Provider.allCases {
            XCTAssertFalse(p.displayName.isEmpty, "\(p) has empty displayName")
        }
    }

    func testDefaultRegions() {
        XCTAssertEqual(S3Provider.aws.defaultRegion, "us-east-1")
        XCTAssertEqual(S3Provider.cloudflareR2.defaultRegion, "auto")
        XCTAssertEqual(S3Provider.backblazeB2.defaultRegion, "us-west-002")
        XCTAssertEqual(S3Provider.wasabi.defaultRegion, "us-east-1")
        XCTAssertEqual(S3Provider.digitalOcean.defaultRegion, "nyc3")
        XCTAssertEqual(S3Provider.minio.defaultRegion, "us-east-1")
        XCTAssertEqual(S3Provider.other.defaultRegion, "")
    }

    func testDefaultEndpoints() {
        XCTAssertNil(S3Provider.aws.defaultEndpoint)
        XCTAssertNil(S3Provider.other.defaultEndpoint)
        XCTAssertEqual(S3Provider.wasabi.defaultEndpoint, "https://s3.wasabisys.com")
        XCTAssertEqual(S3Provider.minio.defaultEndpoint, "http://127.0.0.1:9000")
        XCTAssertNotNil(S3Provider.cloudflareR2.defaultEndpoint)
        XCTAssertNotNil(S3Provider.backblazeB2.defaultEndpoint)
        XCTAssertNotNil(S3Provider.digitalOcean.defaultEndpoint)
    }

    func testBackendCodableRoundTrip() throws {
        let backends: [Backend] = [
            .sftp(SFTPConfig(host: "h", port: 22, user: "u", remotePath: "/", authKind: .generatedKey)),
            .s3(S3Config(provider: .wasabi, region: "us-east-1", endpoint: nil, bucket: "b", prefix: "p")),
            .ftp(FTPConfig(host: "f", port: 990, user: "u", remotePath: "/", tlsMode: .implicit)),
        ]
        for b in backends {
            let data = try JSONEncoder().encode(b)
            XCTAssertEqual(try JSONDecoder().decode(Backend.self, from: data), b)
        }
    }

    func testFTPTLSModeRawValues() {
        XCTAssertEqual(FTPTLSMode.allCases.map(\.rawValue), ["off", "explicit", "implicit"])
    }
}
