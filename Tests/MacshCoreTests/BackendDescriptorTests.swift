import XCTest
@testable import MacshCore

final class BackendDescriptorTests: XCTestCase {
    private let d = BackendDescriptor.webdav
    private let valid = ["url": "https://cloud.example.com/remote.php/dav/files/bob/",
                         "vendor": "nextcloud", "user": "bob", "pass": "secret"]

    func testRegistryFindsWebDAVByType() {
        XCTAssertEqual(BackendDescriptor.descriptor(forType: "webdav"), .webdav)
        XCTAssertNil(BackendDescriptor.descriptor(forType: "nope"))
        XCTAssertTrue(BackendDescriptor.all.contains(.webdav))
    }

    func testDefaultValuesComeFromFields() {
        XCTAssertEqual(d.defaultValues["vendor"], "nextcloud")
        XCTAssertEqual(d.defaultValues["url"], "")
    }

    func testValidInputPasses() {
        XCTAssertNil(d.validate(values: valid, isEditing: false))
    }

    func testRequiredFieldsReported() {
        var v = valid; v["user"] = "  "
        XCTAssertEqual(d.validate(values: v, isEditing: false), "User required")
        v = valid; v["url"] = ""
        XCTAssertEqual(d.validate(values: v, isEditing: false), "URL required")
        v = valid; v["pass"] = ""
        XCTAssertEqual(d.validate(values: v, isEditing: false), "Password required")
    }

    func testBlankSecretAllowedOnlyWhenEditing() {
        var v = valid; v["pass"] = ""
        XCTAssertNil(d.validate(values: v, isEditing: true))
        v["user"] = ""
        XCTAssertEqual(d.validate(values: v, isEditing: true), "User required")
    }

    func testURLMustBeHTTP() {
        for bad in ["cloud.example.com", "ftp://cloud.example.com/x", "https://", "not a url"] {
            var v = valid; v["url"] = bad
            XCTAssertEqual(d.validate(values: v, isEditing: false),
                           "URL must be an http:// or https:// URL", bad)
        }
        var v = valid; v["url"] = "http://192.168.1.5:8080/dav"
        XCTAssertNil(d.validate(values: v, isEditing: false))
    }

    func testChoiceMustBeOneOfAllowed() {
        var v = valid; v["vendor"] = "dropbox"
        XCTAssertEqual(d.validate(values: v, isEditing: false),
                       "Server must be one of: nextcloud, owncloud, other")
    }

    func testMakeConfigSplitsSecretsFromOptions() {
        let cfg = d.makeConfig(values: valid, remotePath: "docs")
        XCTAssertEqual(cfg.type, "webdav")
        XCTAssertEqual(cfg.options, ["url": valid["url"]!, "vendor": "nextcloud", "user": "bob"])
        XCTAssertNil(cfg.options["pass"], "secret must never be a plain option")
        XCTAssertEqual(cfg.secretOptions, [RcloneSecretOption(name: "pass", obscure: true)])
        XCTAssertEqual(cfg.remotePath, "docs")
    }

    func testMakeConfigDropsEmptyAndTrims() {
        var v = valid; v["vendor"] = ""; v["user"] = " bob "
        let cfg = d.makeConfig(values: v, remotePath: "")
        XCTAssertNil(cfg.options["vendor"])
        XCTAssertEqual(cfg.options["user"], "bob")
    }

    func testSecretValuesOnlyIncludeSecretFields() {
        XCTAssertEqual(d.secretValues(from: valid), ["pass": "secret"])
        XCTAssertEqual(d.secretValues(from: [:]), ["pass": ""])
    }

    func testBackendRoundTripsThroughJSONAndRemote() throws {
        let remote = makeRemote(backend: webdavBackend())
        let data = try JSONEncoder().encode(remote)
        XCTAssertEqual(try JSONDecoder().decode(Remote.self, from: data), remote)
    }

    func testExistingBackendsStillDecodeFromLegacyJSON() throws {
        let remote = makeRemote(backend: ftpBackend())
        let data = try JSONEncoder().encode([remote])
        XCTAssertEqual(try JSONDecoder().decode([Remote].self, from: data), [remote])
    }

    func testSecretKindOptionIsDistinctFromBuiltIns() {
        XCTAssertEqual(SecretKind.option("pass").rawValue, "option.pass")
        XCTAssertNotEqual(SecretKind.option("password"), SecretKind.password)
        XCTAssertEqual(SecretKind.password.rawValue, "password", "existing Keychain items must keep resolving")
    }
}

final class GoogleDriveDescriptorTests: XCTestCase {
    private let d = BackendDescriptor.googleDrive
    private let token = #"{"access_token":"AT","refresh_token":"RT"}"#

    func testRegistryAndOAuthSpec() {
        XCTAssertEqual(BackendDescriptor.descriptor(forType: "drive"), .googleDrive)
        XCTAssertEqual(d.oauth?.backend, "drive")
        XCTAssertEqual(d.oauth?.scopeKey, "scope")
        XCTAssertNil(BackendDescriptor.webdav.oauth)
    }

    func testSignInRequiredUnlessEditing() {
        XCTAssertEqual(d.validate(values: d.defaultValues, isEditing: false), "Account required")
        XCTAssertNil(d.validate(values: d.defaultValues, isEditing: true), "saved sign-in is kept")
        var v = d.defaultValues; v["token"] = token
        XCTAssertNil(d.validate(values: v, isEditing: false))
    }

    func testScopeMustBeAllowed() {
        var v = d.defaultValues; v["token"] = token; v["scope"] = "everything"
        XCTAssertNotNil(d.validate(values: v, isEditing: false))
    }

    func testConfigKeepsTokenAndClientSecretOutOfOptions() {
        var v = d.defaultValues
        v["token"] = token; v["client_id"] = "cid"; v["client_secret"] = "cs"; v["team_drive"] = "TD"
        let cfg = d.makeConfig(values: v, remotePath: "Docs")
        XCTAssertEqual(cfg.type, "drive")
        XCTAssertEqual(cfg.options, ["scope": "drive", "client_id": "cid", "team_drive": "TD"])
        XCTAssertEqual(cfg.secretOptions, [
            RcloneSecretOption(name: "token", obscure: false, required: true, refreshable: true),
            RcloneSecretOption(name: "client_secret", obscure: false, required: false, refreshable: false),
        ])
        XCTAssertEqual(d.secretValues(from: v), ["token": token, "client_secret": "cs"])
    }

    func testSecretOptionDecodesFromOlderJSON() throws {
        let old = Data(#"{"name":"pass","obscure":true}"#.utf8)
        let opt = try JSONDecoder().decode(RcloneSecretOption.self, from: old)
        XCTAssertEqual(opt, RcloneSecretOption(name: "pass", obscure: true, required: true, refreshable: false))
        let round = try JSONDecoder().decode(
            RcloneSecretOption.self,
            from: JSONEncoder().encode(RcloneSecretOption(name: "t", obscure: false, required: false, refreshable: true)))
        XCTAssertEqual(round.refreshable, true)
        XCTAssertEqual(round.required, false)
    }

    func testBuilderRequiresTokenButNotClientSecret() throws {
        let r = makeRemote(backend: driveBackend(clientID: "cid"))
        XCTAssertThrowsError(try RcloneConfigBuilder.build(remote: r, secrets: BackendSecrets())) {
            XCTAssertEqual($0 as? RcloneConfigError, .missingSecret("token"))
        }
        let cfg = try RcloneConfigBuilder.build(remote: r, secrets: BackendSecrets(options: ["token": "T"]))
        XCTAssertEqual(cfg, "[r]\ntype = drive\nclient_id = cid\nscope = drive\n")
        XCTAssertFalse(cfg.contains("token"))
    }
}

final class SMBDescriptorTests: XCTestCase {
    private let d = BackendDescriptor.smb
    private let valid = ["host": "nas.local", "port": "445", "user": "bob", "pass": "pw", "domain": ""]

    func testRegistryAndDefaults() {
        XCTAssertEqual(BackendDescriptor.descriptor(forType: "smb"), .smb)
        XCTAssertEqual(d.defaultValues["port"], "445")
        XCTAssertTrue(d.remotePathRequired)
        XCTAssertFalse(BackendDescriptor.webdav.remotePathRequired)
    }

    func testRequiredFieldsAndPortRange() {
        XCTAssertNil(d.validate(values: valid, isEditing: false))
        var v = valid; v["host"] = ""
        XCTAssertEqual(d.validate(values: v, isEditing: false), "Host required")
        v = valid; v["pass"] = ""
        XCTAssertEqual(d.validate(values: v, isEditing: false), "Password required")
        XCTAssertNil(d.validate(values: v, isEditing: true), "blank password keeps the saved one")
        for bad in ["0", "65536", "abc", "-1", "44 5"] {
            v = valid; v["port"] = bad
            XCTAssertEqual(d.validate(values: v, isEditing: false), "Port must be 1-65535", bad)
        }
        v = valid; v["port"] = ""
        XCTAssertNil(d.validate(values: v, isEditing: false), "empty port falls back to rclone's default")
    }

    func testShareIsRequired() {
        XCTAssertEqual(d.validateRemotePath(""), "Share required")
        XCTAssertEqual(d.validateRemotePath("   "), "Share required")
        XCTAssertNil(d.validateRemotePath("media"))
        XCTAssertNil(d.validateRemotePath("media/photos"))
        XCTAssertNil(BackendDescriptor.webdav.validateRemotePath(""))
    }

    func testConfigKeepsPasswordOutOfOptions() {
        var v = valid; v["domain"] = "HOME"
        let cfg = d.makeConfig(values: v, remotePath: "media/photos")
        XCTAssertEqual(cfg.type, "smb")
        XCTAssertEqual(cfg.options, ["host": "nas.local", "port": "445", "user": "bob", "domain": "HOME"])
        XCTAssertEqual(cfg.secretOptions, [RcloneSecretOption(name: "pass", obscure: true)])
        XCTAssertEqual(cfg.remotePath, "media/photos")
        let text = try? RcloneConfigBuilder.build(
            remote: makeRemote(backend: .rclone(cfg)), secrets: BackendSecrets(options: ["pass": "SECRET"]))
        XCTAssertEqual(text, "[r]\ntype = smb\ndomain = HOME\nhost = nas.local\nport = 445\nuser = bob\n")
    }
}

final class NativeCloudDescriptorTests: XCTestCase {
    func testRegistry() {
        XCTAssertEqual(BackendDescriptor.descriptor(forType: "azureblob"), .azureBlob)
        XCTAssertEqual(BackendDescriptor.descriptor(forType: "b2"), .backblazeB2)
        XCTAssertEqual(BackendDescriptor.descriptor(forType: "google cloud storage"), .googleCloudStorage)
        for d in [BackendDescriptor.azureBlob, .backblazeB2, .googleCloudStorage] {
            XCTAssertTrue(d.remotePathRequired, d.type)
        }
    }

    func testAzureKeepsKeyOutOfOptions() {
        let d = BackendDescriptor.azureBlob
        let v = ["account": "acct", "key": "SECRETKEY", "endpoint": ""]
        XCTAssertNil(d.validate(values: v, isEditing: false))
        let cfg = d.makeConfig(values: v, remotePath: "box")
        XCTAssertEqual(cfg.options, ["account": "acct"])
        XCTAssertEqual(cfg.secretOptions.map(\.name), ["key"])
        XCTAssertFalse(cfg.secretOptions[0].obscure)
        XCTAssertEqual(d.validate(values: ["account": "a", "key": ""], isEditing: false), "Account key required")
        XCTAssertEqual(d.validate(values: ["account": "a", "key": "k", "endpoint": "ftp://x"], isEditing: false),
                       "Endpoint must be an http:// or https:// URL")
    }

    func testB2AndGCSSecrets() {
        let b2 = BackendDescriptor.backblazeB2.makeConfig(values: ["account": "id", "key": "k"], remotePath: "bkt")
        XCTAssertEqual(b2.type, "b2")
        XCTAssertEqual(b2.options, ["account": "id"])
        let g = BackendDescriptor.googleCloudStorage
        let cfg = g.makeConfig(values: ["service_account_credentials": "{\"a\":1}", "project_number": "42"], remotePath: "b")
        XCTAssertEqual(cfg.options, ["project_number": "42"])
        XCTAssertEqual(cfg.secretOptions.map(\.name), ["service_account_credentials"])
        let text = try! RcloneConfigBuilder.build(
            remote: Remote(id: UUID(), name: "g", backend: .rclone(cfg), mountProtocol: .webdav, autoMount: false),
            secrets: BackendSecrets(options: ["service_account_credentials": "{\"a\":1}"]))
        XCTAssertTrue(text.contains("type = google cloud storage"))
        XCTAssertFalse(text.contains("\"a\""))
    }
}

final class RawBackendInputTests: XCTestCase {
    func testParsesLinesCommentsAndEqualsInValues() throws {
        let p = try RawBackendInput.parse("# c\n\nregion = eu=1\n  use_emulator=true ")
        XCTAssertEqual(p.map(\.key), ["region", "use_emulator"])
        XCTAssertEqual(p.map(\.value), ["eu=1", "true"])
    }

    func testParseErrors() {
        XCTAssertThrowsError(try RawBackendInput.parse("nothing")) { XCTAssertEqual($0 as? RawBackendError, .badLine(1)) }
        XCTAssertThrowsError(try RawBackendInput.parse("Bad-Key = 1")) { XCTAssertEqual($0 as? RawBackendError, .badKey("Bad-Key")) }
        XCTAssertThrowsError(try RawBackendInput.parse("a=1\na=2")) { XCTAssertEqual($0 as? RawBackendError, .duplicate("a")) }
        XCTAssertEqual(RawBackendError.badLine(3).message, "Line 3 must look like name = value")
        XCTAssertTrue(RawBackendError.badKey("X").message.contains("\"X\""))
        XCTAssertTrue(RawBackendError.duplicate("a").message.contains("twice"))
    }

    func testValidation() {
        var r = RawBackendInput(type: "azureblob", plainText: "account = a", secretText: "key = k")
        XCTAssertNil(r.validate(isEditing: false))
        r.type = " "; XCTAssertEqual(r.validate(isEditing: false), "Backend type required")
        r.type = "Azure!"; XCTAssertNotNil(r.validate(isEditing: false))
        r = RawBackendInput(type: "b2", plainText: "key = k")
        XCTAssertTrue(r.validate(isEditing: false)!.contains("looks like a secret"))
        r = RawBackendInput(type: "b2", plainText: "type = s3")
        XCTAssertTrue(r.validate(isEditing: false)!.contains("type field"))
        r = RawBackendInput(type: "b2", secretText: "type = s3")
        XCTAssertTrue(r.validate(isEditing: false)!.contains("type field"))
        r = RawBackendInput(type: "b2", plainText: "account = 1", secretText: "account = 2")
        XCTAssertTrue(r.validate(isEditing: false)!.contains("plain and secret"))
        r = RawBackendInput(type: "b2", secretText: "app_secret =")
        XCTAssertTrue(r.validate(isEditing: false)!.contains("no value"))
        XCTAssertNil(r.validate(isEditing: true))
        r = RawBackendInput(type: "b2", plainText: "oops")
        XCTAssertEqual(r.validate(isEditing: false), "Line 1 must look like name = value")
    }

    func testSecretsNeverReachPlainOptions() throws {
        let r = RawBackendInput(type: "azureblob", plainText: "account = a\nendpoint =", secretText: "sas_url = https://x?sig=1",
                                remotePath: " box ")
        let (cfg, secrets) = try r.makeConfig()
        XCTAssertEqual(cfg.options, ["account": "a"])
        XCTAssertEqual(cfg.secretOptions.map(\.name), ["sas_url"])
        XCTAssertEqual(secrets, ["sas_url": "https://x?sig=1"])
        XCTAssertEqual(cfg.remotePath, "box")
        let json = String(data: try JSONEncoder().encode(cfg), encoding: .utf8)!
        XCTAssertFalse(json.contains("sig=1"))
        XCTAssertEqual(RawBackendInput.plainText(of: cfg), "account = a")
    }

    func testEditingKeepsSavedSecretNames() throws {
        let saved = [RcloneSecretOption(name: "key", obscure: false)]
        let (cfg, secrets) = try RawBackendInput(type: "b2", plainText: "account = a").makeConfig(keeping: saved)
        XCTAssertEqual(cfg.secretOptions, saved)
        XCTAssertTrue(secrets.isEmpty)
    }
}
