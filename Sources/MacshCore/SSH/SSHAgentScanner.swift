import Foundation

public struct SSHAgentCandidate: Identifiable, Sendable, Equatable {
    public let id: String   // stable = path
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.id = path
        self.name = name
        self.path = path
    }

    public var displayPath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }
}

public enum SSHAgentScanner {
    // Known password-manager / agent sockets (home-relative paths).
    // Multiple entries per app cover different versions / install methods.
    private static let knownAgents: [(String, String)] = [
        // Bitwarden — sandbox container path (newer) and legacy symlink
        ("Bitwarden",  "Library/Containers/com.bitwarden.desktop/Data/.bitwarden-ssh-agent.sock"),
        ("Bitwarden",  ".bitwarden-ssh-agent.sock"),
        // 1Password — real socket and the symlink users are told to create
        ("1Password",  "Library/Group Containers/2BUA8C4S2C.com.1password/t/agent.sock"),
        ("1Password",  ".1password/agent.sock"),
        // KeePassXC
        ("KeePassXC",  ".keepassxc/agent.sock"),
        // GPG Agent
        ("GPG Agent",  ".gnupg/S.gpg-agent.ssh"),
        // Secretive (open-source macOS Secure Enclave SSH agent)
        ("Secretive",  "Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"),
        // NordPass
        ("NordPass",   ".nordpass/ssh-agent.sock"),
    ]

    /// Returns every SSH-agent socket that currently exists on disk.
    /// Pure filesystem existence checks — no subprocess, safe to call on any thread.
    public static func scan() -> [SSHAgentCandidate] {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        var results: [SSHAgentCandidate] = []

        func add(_ name: String, _ path: String) {
            guard fm.fileExists(atPath: path), seen.insert(path).inserted else { return }
            results.append(.init(name: name, path: path))
        }

        // Named password managers first — most likely to have real keys
        for (name, rel) in knownAgents { add(name, "\(home)/\(rel)") }

        // SSH_AUTH_SOCK from environment (may overlap with above)
        if let sock = ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] { add("SSH_AUTH_SOCK", sock) }

        // Keeper Security — socket named "<email>_agent" inside ~/.keeper/
        if let entries = try? fm.contentsOfDirectory(atPath: "\(home)/.keeper") {
            for entry in entries.sorted() where entry.hasSuffix("_agent") {
                add("Keeper", "\(home)/.keeper/\(entry)")
            }
        }

        // macOS built-in SSH agent (launchd socket — path changes each boot)
        if let dirs = try? fm.contentsOfDirectory(atPath: "/private/tmp") {
            for dir in dirs.sorted() where dir.hasPrefix("com.apple.launchd.") {
                add("macOS SSH Agent", "/private/tmp/\(dir)/Listeners")
            }
        }

        return results
    }
}
