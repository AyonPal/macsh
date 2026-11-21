import Foundation

enum LogArchive {
    static func rotate(
        current: URL,
        retention: TimeInterval = 30 * 24 * 3600,
        now: Date = Date(),
        fileManager: FileManager = .default
    ) {
        let directory = current.deletingLastPathComponent()
        if let attributes = try? fileManager.attributesOfItem(atPath: current.path),
           attributes[.type] as? FileAttributeType == .typeRegular,
           let size = attributes[.size] as? NSNumber, size.int64Value > 0 {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let stem = current.deletingPathExtension().lastPathComponent + "." + formatter.string(from: now)
            var archive = directory.appendingPathComponent(stem + ".log")
            var suffix = 1
            while fileManager.fileExists(atPath: archive.path) {
                archive = directory.appendingPathComponent("\(stem)-\(suffix).log")
                suffix += 1
            }
            try? fileManager.moveItem(at: current, to: archive)
        }

        let pattern = #"\A[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}\.[0-9]{8}-[0-9]{6}(-[1-9][0-9]*)?\.log\z"#
        let cutoff = now.addingTimeInterval(-retention)
        let files = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files {
            guard file.lastPathComponent.range(of: pattern, options: .regularExpression) != nil,
                  let attributes = try? fileManager.attributesOfItem(atPath: file.path),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let modified = attributes[.modificationDate] as? Date,
                  modified < cutoff else { continue }
            try? fileManager.removeItem(at: file)
        }
    }
}
