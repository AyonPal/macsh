import XCTest
@testable import MacshCore

/// Real Google Drive through macsh's pipeline. Needs a test account, so it only runs when
/// MACSH_IT_GDRIVE_TOKEN (rclone token JSON from `rclone authorize drive`) is set, e.g. from
/// a CI secret. Optional: MACSH_IT_GDRIVE_CLIENT_ID / _CLIENT_SECRET (own OAuth client, avoids
/// rclone's shared rate limits) and MACSH_IT_GDRIVE_FOLDER (root folder ID to confine the test).
@MainActor
final class GoogleDriveIntegrationTests: XCTestCase {
    private struct Env {
        let token: String, clientID: String, clientSecret: String, folder: String
    }

    private func env() throws -> Env {
        let e = ProcessInfo.processInfo.environment
        guard let token = e["MACSH_IT_GDRIVE_TOKEN"], !token.isEmpty else {
            throw XCTSkip("MACSH_IT_GDRIVE_TOKEN not set (no Google test account configured)")
        }
        return Env(token: token, clientID: e["MACSH_IT_GDRIVE_CLIENT_ID"] ?? "",
                   clientSecret: e["MACSH_IT_GDRIVE_CLIENT_SECRET"] ?? "",
                   folder: e["MACSH_IT_GDRIVE_FOLDER"] ?? "")
    }

    private func backend(_ e: Env) -> Backend {
        .rclone(BackendDescriptor.googleDrive.makeConfig(
            values: ["scope": "drive", "token": "", "client_id": e.clientID, "client_secret": "",
                     "root_folder_id": e.folder],
            remotePath: ""))
    }

    private func secrets(_ e: Env, token: String) -> IntegrationHarness.Secrets {
        var options = ["token": token]
        if !e.clientSecret.isEmpty { options["client_secret"] = e.clientSecret }
        return .init(options: options)
    }

    /// Reads a file straight from Drive with rclone (verification only, not macsh's path).
    private func driveContents(_ file: String, _ e: Env, token: String) -> String? {
        let p = Process()
        p.executableURL = try? RcloneBinary.resolve()
        p.arguments = ["cat", "gd:\(file)"]
        var env = ProcessInfo.processInfo.environment
        env["RCLONE_CONFIG_GD_TYPE"] = "drive"
        env["RCLONE_CONFIG_GD_TOKEN"] = token
        env["RCLONE_CONFIG_GD_SCOPE"] = "drive"
        if !e.clientID.isEmpty { env["RCLONE_CONFIG_GD_CLIENT_ID"] = e.clientID }
        if !e.clientSecret.isEmpty { env["RCLONE_CONFIG_GD_CLIENT_SECRET"] = e.clientSecret }
        if !e.folder.isEmpty { env["RCLONE_CONFIG_GD_ROOT_FOLDER_ID"] = e.folder }
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
            self, backend: backend(e), secrets: secrets(e, token: e.token), proto: proto,
            label: "gdrive-\(proto.rawValue)"
        ) { [self] file in driveContents(file, e, token: e.token) }
    }

    func testGoogleDriveNFSRoundTrip() async throws { try await roundTrip(.nfs) }
    func testGoogleDriveWebDAVRoundTrip() async throws { try await roundTrip(.webdav) }

    /// An expired access token forces rclone to refresh through the refresh token; macsh must
    /// read the refreshed token back out of rclone's config into the Keychain on unmount.
    func testExpiredTokenIsRefreshedAndPersisted() async throws {
        let e = try env()
        guard var obj = try JSONSerialization.jsonObject(with: Data(e.token.utf8)) as? [String: Any] else {
            return XCTFail("token is not a JSON object")
        }
        obj["access_token"] = "expired-on-purpose"
        obj["expiry"] = "2000-01-01T00:00:00Z"
        let stale = String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys]), as: UTF8.self)

        let dir = try makeTempDir()
        let keychain = KeychainService(serviceName: "macsh.it.\(UUID().uuidString)")
        let manager = SessionManager(
            store: RemoteStore(directory: dir), keychain: keychain, mounter: Mounter(),
            logsDir: dir.appendingPathComponent("logs"), rcloneBinary: try RcloneBinary.resolve())
        let remote = Remote(id: UUID(), name: "macsh-it-gdrive-refresh-\(Int.random(in: 1000...9999))",
                            backend: backend(e), mountProtocol: .nfs, autoMount: false)
        try manager.add(remote, optionSecrets: secrets(e, token: stale).options)
        addTeardownBlock { @MainActor in
            manager.shutdownAll(); try? manager.delete(remote.id); try? FileManager.default.removeItem(at: dir)
        }

        try await manager.mount(remoteID: remote.id)
        guard case .mounted(let mp) = manager.sessions[0].status else { return XCTFail("not mounted") }
        _ = try FileManager.default.contentsOfDirectory(atPath: mp)     // forces an API call -> refresh
        try await manager.unmount(remoteID: remote.id)

        let saved = try XCTUnwrap(try keychain.get(remoteID: remote.id, kind: .option("token")))
        XCTAssertNotEqual(saved, stale, "refreshed token was not written back to the Keychain")
        XCTAssertFalse(saved.contains("expired-on-purpose"))
    }
}
