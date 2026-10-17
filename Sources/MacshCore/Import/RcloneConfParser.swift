import Foundation

/// One `[remote]` section of an rclone.conf file.
public struct RcloneConfSection: Equatable {
    public let name: String
    /// Value of the `type` key ("" if missing).
    public let type: String
    /// Every other key. Values stay as written (passwords are still obscured).
    public let options: [String: String]

    public init(name: String, type: String, options: [String: String]) {
        self.name = name
        self.type = type
        self.options = options
    }
}

public enum RcloneConfParser {
    public static func parse(_ text: String) -> [RcloneConfSection] {
        var sections: [RcloneConfSection] = []
        var name: String?
        var options: [String: String] = [:]

        func flush() {
            if let name {
                var opts = options
                let type = opts.removeValue(forKey: "type") ?? ""
                sections.append(RcloneConfSection(name: name, type: type, options: opts))
            }
        }

        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                flush()
                name = String(line.dropFirst().dropLast())
                options = [:]
                continue
            }
            guard name != nil, let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { options[key] = value }
        }
        flush()
        return sections
    }

    /// rclone encrypts the whole file with a password when config encryption is on.
    public static func isEncrypted(_ text: String) -> Bool {
        text.hasPrefix("RCLONE_ENCRYPT_V")
    }

    /// Where rclone looks for its config, in order: `RCLONE_CONFIG`, the XDG location, the
    /// legacy `~/.rclone.conf`.
    public static func candidatePaths(env: [String: String], home: String) -> [String] {
        var paths: [String] = []
        if let p = env["RCLONE_CONFIG"], !p.isEmpty { paths.append(p) }
        let xdg = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? "\(home)/.config"
        paths.append("\(xdg)/rclone/rclone.conf")
        paths.append("\(home)/.rclone.conf")
        return paths
    }

    public static func locate(
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> String? {
        candidatePaths(env: env, home: home).first(where: fileExists)
    }
}
