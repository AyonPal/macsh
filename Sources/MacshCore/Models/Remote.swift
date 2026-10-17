import Foundation

public struct Remote: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var backend: Backend
    public var mountProtocol: MountProtocol
    public var autoMount: Bool
    public var liveUpdates: Bool
    /// nil = `TransferTuning.defaults(for: mountProtocol)`.
    public var tuning: TransferTuning?
    /// Reject writes (`rclone serve --read-only`).
    public var readOnly: Bool
    /// rclone `--bwlimit` such as `10M` or `10M:1M`; nil = unlimited.
    public var bandwidthLimit: String?

    public init(
        id: UUID,
        name: String,
        backend: Backend,
        mountProtocol: MountProtocol,
        autoMount: Bool,
        liveUpdates: Bool = true,
        tuning: TransferTuning? = nil,
        readOnly: Bool = false,
        bandwidthLimit: String? = nil
    ) {
        self.id = id
        self.name = name
        self.backend = backend
        self.mountProtocol = mountProtocol
        self.autoMount = autoMount
        self.liveUpdates = liveUpdates
        self.tuning = tuning
        self.readOnly = readOnly
        self.bandwidthLimit = bandwidthLimit
    }

    /// The tuning actually used when mounting: the saved one, or the defaults for this
    /// remote's protocol and (for generic rclone backends) backend type.
    public var effectiveTuning: TransferTuning {
        if let tuning { return tuning }
        if case .rclone(let cfg) = backend { return .defaults(for: mountProtocol, backendType: cfg.type) }
        return .defaults(for: mountProtocol)
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, backend, mountProtocol, autoMount, liveUpdates, tuning, readOnly, bandwidthLimit
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
        self.tuning = try c.decodeIfPresent(TransferTuning.self, forKey: .tuning)
        self.readOnly = try c.decodeIfPresent(Bool.self, forKey: .readOnly) ?? false
        self.bandwidthLimit = try c.decodeIfPresent(String.self, forKey: .bandwidthLimit)
    }
}

public enum MountProtocol: String, Codable, Equatable, CaseIterable {
    case webdav
    case nfs
}
