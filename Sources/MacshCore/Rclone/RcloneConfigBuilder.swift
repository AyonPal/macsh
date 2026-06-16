import Foundation

public struct SFTPSecrets {
    public let password: String?
    public let privateKeyPath: String?
    public let keyPassphrase: String?

    public init(password: String?, privateKeyPath: String?, keyPassphrase: String?) {
        self.password = password
        self.privateKeyPath = privateKeyPath
        self.keyPassphrase = keyPassphrase
    }
}

public struct S3Secrets {
    public let accessKeyID: String
    public let secretAccessKey: String

    public init(accessKeyID: String, secretAccessKey: String) {
        self.accessKeyID = accessKeyID
        self.secretAccessKey = secretAccessKey
    }
}

public struct FTPSecrets {
    public let password: String

    public init(password: String) {
        self.password = password
    }
}

/// Bundle of optional per-backend secrets handed to the builder.
public struct BackendSecrets {
    public var sftp: SFTPSecrets?
    public var s3: S3Secrets?
    public var ftp: FTPSecrets?

    public init(sftp: SFTPSecrets? = nil, s3: S3Secrets? = nil, ftp: FTPSecrets? = nil) {
        self.sftp = sftp
        self.s3 = s3
        self.ftp = ftp
    }
}

public enum RcloneConfigError: Error, Equatable {
    case keyFileAuthRequiresPath
    case passwordAuthRequiresPassword
    case missingS3Credentials
    case missingFTPPassword
}

public enum RcloneConfigBuilder {
    /// rclone config section name used for every spawned config file. We use a fixed simple
    /// identifier instead of the remote UUID because rclone's env-var override path
    /// (RCLONE_CONFIG_<NAME>_*) doesn't reliably resolve names with hyphens or leading digits.
    public static let sectionName = "r"

    /// Returns the rclone config file text. Sensitive credentials are passed via env at runtime
    /// (RCLONE_CONFIG_R_PASS for SFTP/FTP password, RCLONE_CONFIG_R_SECRET_ACCESS_KEY
    /// for S3 secret), so the on-disk config never contains plaintext or obscured secrets.
    public static func build(remote: Remote, secrets: BackendSecrets, knownHostsPath: String? = nil) throws -> String {
        var lines: [String] = ["[\(sectionName)]"]
        switch remote.backend {
        case .sftp(let cfg):
            guard let s = secrets.sftp else { throw RcloneConfigError.passwordAuthRequiresPassword }
            lines.append("type = sftp")
            lines.append("host = \(cfg.host)")
            lines.append("port = \(cfg.port)")
            lines.append("user = \(cfg.user)")
            switch cfg.authKind {
            case .password:
                guard s.password != nil else { throw RcloneConfigError.passwordAuthRequiresPassword }
            case .keyFile, .generatedKey:
                guard let path = s.privateKeyPath else { throw RcloneConfigError.keyFileAuthRequiresPath }
                lines.append("key_file = \(path)")
            case .sshAgent:
                lines.append("use_agent = true")
            }
            if let kh = knownHostsPath {
                lines.append("known_hosts_file = \(kh)")
            }

        case .s3(let cfg):
            guard let s = secrets.s3 else { throw RcloneConfigError.missingS3Credentials }
            lines.append("type = s3")
            lines.append("provider = \(cfg.provider.rcloneProvider)")
            lines.append("access_key_id = \(s.accessKeyID)")
            // secret comes from env at runtime
            if !cfg.region.isEmpty { lines.append("region = \(cfg.region)") }
            if let endpoint = cfg.endpoint, !endpoint.isEmpty { lines.append("endpoint = \(endpoint)") }

        case .ftp(let cfg):
            guard secrets.ftp != nil else { throw RcloneConfigError.missingFTPPassword }
            lines.append("type = ftp")
            lines.append("host = \(cfg.host)")
            lines.append("port = \(cfg.port)")
            lines.append("user = \(cfg.user)")
            switch cfg.tlsMode {
            case .off: break
            case .explicit: lines.append("tls = true")
            case .implicit: lines.append("tls = true"); lines.append("explicit_tls = false")
            }
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Backwards-compatible SFTP-only entrypoint.
    public static func build(remote: Remote, sftpSecrets: SFTPSecrets, knownHostsPath: String? = nil) throws -> String {
        try build(remote: remote, secrets: BackendSecrets(sftp: sftpSecrets), knownHostsPath: knownHostsPath)
    }

    /// Env var name rclone uses to override the password field at runtime (SFTP / FTP).
    /// See: https://rclone.org/docs/#config-file
    public static func passwordEnvVar(remoteID: UUID) -> String {
        "RCLONE_CONFIG_\(sectionName.uppercased())_PASS"
    }

    /// Env var name for S3 secret access key.
    public static func s3SecretEnvVar(remoteID: UUID) -> String {
        "RCLONE_CONFIG_\(sectionName.uppercased())_SECRET_ACCESS_KEY"
    }
}
