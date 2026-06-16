import Foundation

public enum Backend: Codable, Equatable {
    case sftp(SFTPConfig)
    case s3(S3Config)
    case ftp(FTPConfig)
}

public struct FTPConfig: Codable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    public var remotePath: String
    public var tlsMode: FTPTLSMode

    public init(host: String, port: Int, user: String, remotePath: String, tlsMode: FTPTLSMode) {
        self.host = host
        self.port = port
        self.user = user
        self.remotePath = remotePath
        self.tlsMode = tlsMode
    }
}

public enum FTPTLSMode: String, Codable, Equatable, CaseIterable {
    case off
    case explicit   // FTPS-explicit (AUTH TLS on port 21)
    case implicit   // FTPS-implicit (TLS-from-start, typically port 990)
}

public struct SFTPConfig: Codable, Equatable {
    public var host: String
    public var port: Int
    public var user: String
    public var remotePath: String
    public var authKind: SFTPAuthKind

    public init(host: String, port: Int, user: String, remotePath: String, authKind: SFTPAuthKind) {
        self.host = host
        self.port = port
        self.user = user
        self.remotePath = remotePath
        self.authKind = authKind
    }
}

public enum SFTPAuthKind: String, Codable, Equatable {
    case password
    case keyFile        // path to existing private key (path stored in Keychain)
    case generatedKey   // app-generated key; private PEM stored in Keychain
    case sshAgent       // delegate auth to the system SSH agent (SSH_AUTH_SOCK)
}

public struct S3Config: Codable, Equatable {
    public var provider: S3Provider
    public var region: String
    public var endpoint: String?   // nil = use provider default / AWS region routing
    public var bucket: String
    public var prefix: String      // empty = bucket root

    public init(provider: S3Provider, region: String, endpoint: String?, bucket: String, prefix: String) {
        self.provider = provider
        self.region = region
        self.endpoint = endpoint
        self.bucket = bucket
        self.prefix = prefix
    }
}

/// Storage form of the S3 provider (distinct cases for distinct UIs/defaults).
/// `rcloneProvider` maps to the value rclone expects in its config (some collapse to "Other").
public enum S3Provider: String, Codable, Equatable, CaseIterable {
    case aws
    case cloudflareR2
    case backblazeB2
    case wasabi
    case minio
    case digitalOcean
    case other

    /// Value emitted in rclone config `provider = ...`.
    public var rcloneProvider: String {
        switch self {
        case .aws: return "AWS"
        case .cloudflareR2: return "Cloudflare"
        case .wasabi: return "Wasabi"
        case .minio: return "Minio"
        case .digitalOcean: return "DigitalOcean"
        case .backblazeB2, .other: return "Other"
        }
    }

    public var displayName: String {
        switch self {
        case .aws: return "AWS S3"
        case .cloudflareR2: return "Cloudflare R2"
        case .backblazeB2: return "Backblaze B2 (S3)"
        case .wasabi: return "Wasabi"
        case .minio: return "MinIO"
        case .digitalOcean: return "DigitalOcean Spaces"
        case .other: return "Other (S3-compatible)"
        }
    }

    public var defaultRegion: String {
        switch self {
        case .aws: return "us-east-1"
        case .cloudflareR2: return "auto"
        case .backblazeB2: return "us-west-002"
        case .wasabi: return "us-east-1"
        case .digitalOcean: return "nyc3"
        case .minio: return "us-east-1"
        case .other: return ""
        }
    }

    public var defaultEndpoint: String? {
        switch self {
        case .aws: return nil
        case .cloudflareR2: return "https://<account-id>.r2.cloudflarestorage.com"
        case .backblazeB2: return "https://s3.us-west-002.backblazeb2.com"
        case .wasabi: return "https://s3.wasabisys.com"
        case .digitalOcean: return "https://nyc3.digitaloceanspaces.com"
        case .minio: return "http://127.0.0.1:9000"
        case .other: return nil
        }
    }
}
