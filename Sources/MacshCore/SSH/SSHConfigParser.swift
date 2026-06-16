import Foundation

public struct SSHConfigHost: Identifiable, Sendable {
    public let id = UUID()
    public let alias: String
    public let hostname: String
    public let user: String?
    public let port: Int
    public let identityFile: String?

    public init(alias: String, hostname: String, user: String?, port: Int, identityFile: String?) {
        self.alias = alias
        self.hostname = hostname
        self.user = user
        self.port = port
        self.identityFile = identityFile
    }
}

public enum SSHConfigParser {
    public static func defaultConfigHosts() -> [SSHConfigHost] {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ssh/config")
        return parse(url: url)
    }

    public static func parse(url: URL) -> [SSHConfigHost] {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        return parse(content: content)
    }

    static func parse(content: String) -> [SSHConfigHost] {
        var hosts: [SSHConfigHost] = []
        var alias: String? = nil
        var hostname: String? = nil
        var user: String? = nil
        var port: Int = 22
        var identityFile: String? = nil

        func flush() {
            guard let a = alias, !a.isEmpty, !a.contains("*"), !a.contains("?") else { return }
            hosts.append(SSHConfigHost(
                alias: a,
                hostname: hostname ?? a,
                user: user,
                port: port,
                identityFile: identityFile.map(expandTilde)
            ))
        }

        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { continue }

            let sep = trimmed.firstIndex(where: { $0.isWhitespace || $0 == "=" })
            guard let sep else { continue }
            let key = trimmed[trimmed.startIndex..<sep].lowercased()
            let rest = trimmed[sep...].drop(while: { $0.isWhitespace || $0 == "=" })
            let value = String(rest).trimmingCharacters(in: .whitespaces)
            guard !value.isEmpty else { continue }

            switch key {
            case "host":
                flush()
                alias = value
                hostname = nil; user = nil; port = 22; identityFile = nil
            case "hostname":
                hostname = value
            case "user":
                user = value
            case "port":
                port = Int(value) ?? 22
            case "identityfile":
                identityFile = value
            default:
                break
            }
        }
        flush()
        return hosts
    }

    private static func expandTilde(_ path: String) -> String {
        guard path.hasPrefix("~") else { return path }
        return FileManager.default.homeDirectoryForCurrentUser.path + path.dropFirst()
    }
}
