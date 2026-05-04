import Foundation

public struct Remote: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var backend: Backend
    public var mountProtocol: MountProtocol
    public var autoMount: Bool
    public var liveUpdates: Bool

    public init(
        id: UUID,
        name: String,
        backend: Backend,
        mountProtocol: MountProtocol,
        autoMount: Bool,
        liveUpdates: Bool = true
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.mountProtocol = mountProtocol
        self.autoMount = autoMount
        self.liveUpdates = liveUpdates
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, backend, mountProtocol, autoMount, liveUpdates
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.name = try c.decode(String.self, forKey: .name)
        self.backend = try c.decode(Backend.self, forKey: .backend)
        self.mountProtocol = try c.decode(MountProtocol.self, forKey: .mountProtocol)
        self.autoMount = try c.decode(Bool.self, forKey: .autoMount)
        // Pre-existing remotes.json files predate this field; default to live (matches the form default).
        self.liveUpdates = try c.decodeIfPresent(Bool.self, forKey: .liveUpdates) ?? true
    }
}

public enum MountProtocol: String, Codable, Equatable, CaseIterable {
    case webdav
    case nfs
}
