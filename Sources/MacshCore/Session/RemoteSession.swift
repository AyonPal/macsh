import Foundation
import Combine

public final class RemoteSession: ObservableObject, Identifiable {
    public internal(set) var remote: Remote
    @Published public private(set) var status: SessionStatus = .idle

    /// Populated while in `.mounted` or `.starting`. Set by SessionManager.
    public internal(set) var rcloneProcess: Process?
    public internal(set) var mountpoint: String?
    /// For generated-key remotes, the temp file containing the decrypted private key
    /// while the mount is active. Cleaned up on unmount.
    public internal(set) var ephemeralKeyURL: URL?

    public var id: UUID { remote.id }

    public init(remote: Remote) {
        self.remote = remote
    }

    public func transition(to newStatus: SessionStatus) {
        if Thread.isMainThread {
            self.status = newStatus
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.status = newStatus
            }
        }
    }
}
