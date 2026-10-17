import XCTest
@testable import MacshCore

/// Azure Blob against Azurite (Microsoft's emulator, started by scripts/ci/start-azurite.sh),
/// both through the Azure form's descriptor and through the raw-options escape hatch.
/// Backblaze B2 and Google Cloud Storage have no usable emulator, so their tests need test
/// accounts (see `NativeCloudAccountTests`) and skip without them.
@MainActor
final class AzureIntegrationTests: XCTestCase {
    private struct Env { let account, key, endpoint, container: String }

    private func env() throws -> Env {
        let e = try IntegrationEnv.require("MACSH_IT_AZ_ACCOUNT", "MACSH_IT_AZ_KEY", "MACSH_IT_AZ_ENDPOINT",
                                           "MACSH_IT_AZ_CONTAINER")
        return Env(account: e["MACSH_IT_AZ_ACCOUNT"]!, key: e["MACSH_IT_AZ_KEY"]!,
                   endpoint: e["MACSH_IT_AZ_ENDPOINT"]!, container: e["MACSH_IT_AZ_CONTAINER"]!)
    }

    private func backend(_ e: Env, container: String? = nil, endpoint: String? = nil) -> Backend {
        .rclone(BackendDescriptor.azureBlob.makeConfig(
            values: ["account": e.account, "key": "", "endpoint": endpoint ?? e.endpoint],
            remotePath: container ?? e.container))
    }

    /// Reads a blob straight from the emulator (verification only, not macsh's path).
    private func blob(_ file: String, _ e: Env) -> String? {
        let p = Process()
        p.executableURL = try? RcloneBinary.resolve()
        p.arguments = ["cat", "az:\(e.container)/\(file)"]
        var env = ProcessInfo.processInfo.environment
        env["RCLONE_CONFIG_AZ_TYPE"] = "azureblob"
        env["RCLONE_CONFIG_AZ_ACCOUNT"] = e.account
        env["RCLONE_CONFIG_AZ_KEY"] = e.key
        env["RCLONE_CONFIG_AZ_ENDPOINT"] = e.endpoint
        p.environment = env
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    private func roundTrip(_ proto: MountProtocol) async throws {
        let e = try env()
        try await IntegrationHarness.roundTrip(
            self, backend: backend(e), secrets: .init(options: ["key": e.key]), proto: proto,
            label: "azure-\(proto.rawValue)") { [self] f in blob(f, e) }
    }

    func testAzureNFS() async throws { try await roundTrip(.nfs) }
    func testAzureWebDAV() async throws { try await roundTrip(.webdav) }

    /// The "Other rclone backend" path: type and options typed as text, key as a secret option.
    func testRawOptionsBackendMountsAzure() async throws {
        let e = try env()
        let raw = RawBackendInput(
            type: "azureblob",
            plainText: "account = \(e.account)\nendpoint = \(e.endpoint)",
            secretText: "key = \(e.key)", remotePath: e.container)
        XCTAssertNil(raw.validate(isEditing: false))
        let (cfg, secrets) = try raw.makeConfig()
        try await IntegrationHarness.roundTrip(
            self, backend: .rclone(cfg), secrets: .init(options: secrets), proto: .webdav,
            label: "azure-raw") { [self] f in blob(f, e) }
    }

    func testConnectionGoodBadKeyUnreachableAndMissingContainer() async throws {
        let e = try env()
        let good = try await IntegrationHarness.connectionTest(self, backend: backend(e), draft: .init(options: ["key": e.key]))
        XCTAssertTrue(good.ok, "\(good.message) | \(good.detail)")

        let badKey = String(e.key.reversed())
        let bad = try await IntegrationHarness.connectionTest(self, backend: backend(e), draft: .init(options: ["key": badKey]))
        XCTAssertFalse(bad.ok, "a wrong key must fail")

        let down = try await IntegrationHarness.connectionTest(
            self, backend: backend(e, endpoint: "http://127.0.0.1:1/\(e.account)"), draft: .init(options: ["key": e.key]))
        XCTAssertFalse(down.ok)
        XCTAssertTrue(down.message.hasPrefix("Could not reach the server"), "\(down.message) | \(down.detail)")

        let missing = try await IntegrationHarness.connectionTest(
            self, backend: backend(e, container: "no-such-container"), draft: .init(options: ["key": e.key]))
        XCTAssertFalse(missing.ok)
    }
}

/// Real Backblaze B2 and Google Cloud Storage accounts. Skipped without the CI secrets
/// MACSH_IT_B2_ACCOUNT/_KEY/_BUCKET and MACSH_IT_GCS_CREDENTIALS/_BUCKET.
@MainActor
final class NativeCloudAccountTests: XCTestCase {
    private func rcloneCat(_ target: String, _ env: [String: String]) -> String? {
        let p = Process()
        p.executableURL = try? RcloneBinary.resolve()
        p.arguments = ["cat", target]
        p.environment = ProcessInfo.processInfo.environment.merging(env) { $1 }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return p.terminationStatus == 0 ? String(data: data, encoding: .utf8) : nil
    }

    func testBackblazeB2RoundTrip() async throws {
        let e = try IntegrationEnv.require("MACSH_IT_B2_ACCOUNT", "MACSH_IT_B2_KEY", "MACSH_IT_B2_BUCKET")
        let backend = Backend.rclone(BackendDescriptor.backblazeB2.makeConfig(
            values: ["account": e["MACSH_IT_B2_ACCOUNT"]!, "key": ""], remotePath: e["MACSH_IT_B2_BUCKET"]!))
        let conf = ["RCLONE_CONFIG_B_TYPE": "b2", "RCLONE_CONFIG_B_ACCOUNT": e["MACSH_IT_B2_ACCOUNT"]!,
                    "RCLONE_CONFIG_B_KEY": e["MACSH_IT_B2_KEY"]!]
        try await IntegrationHarness.roundTrip(
            self, backend: backend, secrets: .init(options: ["key": e["MACSH_IT_B2_KEY"]!]), proto: .webdav,
            label: "b2") { [self] f in rcloneCat("b:\(e["MACSH_IT_B2_BUCKET"]!)/\(f)", conf) }
    }

    func testGoogleCloudStorageRoundTrip() async throws {
        let e = try IntegrationEnv.require("MACSH_IT_GCS_CREDENTIALS", "MACSH_IT_GCS_BUCKET")
        let backend = Backend.rclone(BackendDescriptor.googleCloudStorage.makeConfig(
            values: ["service_account_credentials": "", "project_number": ProcessInfo.processInfo.environment["MACSH_IT_GCS_PROJECT"] ?? ""],
            remotePath: e["MACSH_IT_GCS_BUCKET"]!))
        let conf = ["RCLONE_CONFIG_G_TYPE": "google cloud storage",
                    "RCLONE_CONFIG_G_SERVICE_ACCOUNT_CREDENTIALS": e["MACSH_IT_GCS_CREDENTIALS"]!]
        try await IntegrationHarness.roundTrip(
            self, backend: backend,
            secrets: .init(options: ["service_account_credentials": e["MACSH_IT_GCS_CREDENTIALS"]!]), proto: .webdav,
            label: "gcs") { [self] f in rcloneCat("g:\(e["MACSH_IT_GCS_BUCKET"]!)/\(f)", conf) }
    }
}
