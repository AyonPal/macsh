import Foundation

/// Cheap sanity check for the private key file chosen in the SFTP form, so a wrong file
/// (a `.pub`, a missing path) is reported at save time instead of as an rclone
/// "ssh: no key found" at mount time.
public enum KeyFileValidator {
    /// Returns a user-facing message, or nil when the file looks like a private key.
    public static func validate(path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), !isDir.boolValue else {
            return "Key file not found: \(path)"
        }
        guard let handle = FileHandle(forReadingAtPath: expanded) else {
            return "Key file is not readable: \(path)"
        }
        defer { try? handle.close() }
        let head = String(decoding: handle.readData(ofLength: 4096), as: UTF8.self)
        if head.hasPrefix("ssh-") || head.hasPrefix("ecdsa-") || head.hasPrefix("sk-") {
            return "That looks like a public key (.pub). Choose the private key file."
        }
        if !head.contains("PRIVATE KEY-----") {
            return "That file does not look like a private key (no \"BEGIN ... PRIVATE KEY\" block)."
        }
        return nil
    }
}
