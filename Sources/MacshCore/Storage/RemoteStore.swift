import Foundation

public final class RemoteStore {
    private let fileURL: URL
    private let fileManager: FileManager

    public init(directory: URL, fileManager: FileManager = .default) {
        self.fileURL = directory.appendingPathComponent("remotes.json")
        self.fileManager = fileManager
    }

    public func load() throws -> [Remote] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        let data = try Data(contentsOf: fileURL)
        return try JSONDecoder().decode([Remote].self, from: data)
    }

    public func save(_ remotes: [Remote]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(remotes)
        try data.write(to: fileURL, options: .atomic)
    }
}
