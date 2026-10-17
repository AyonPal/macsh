import Foundation

/// Reads values back out of an rclone config file (`key = value` lines).
public enum RcloneConfigReader {
    /// Value of `key` in the `[r]` section (the only one macsh writes), or nil.
    public static func value(of key: String, in text: String, section: String = RcloneConfigBuilder.sectionName) -> String? {
        var inSection = false
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inSection = String(line.dropFirst().dropLast()) == section
                continue
            }
            guard inSection, let eq = line.range(of: "=") else { continue }
            if line[..<eq.lowerBound].trimmingCharacters(in: .whitespaces) == key {
                return line[eq.upperBound...].trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
