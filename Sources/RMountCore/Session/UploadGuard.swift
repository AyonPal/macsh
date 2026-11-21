import Foundation

public struct UploadWarning: Equatable {
    public let messageText: String
    public let informativeText: String
    public let confirmButtonTitle: String
    public let waitButtonTitle: String
}

public enum UploadGuard {
    public enum Action { case quit, unmount, installUpdate }

    public static func warning(for action: Action, uploads: [(remoteName: String, status: UploadStatus)]) -> UploadWarning? {
        let pending = uploads.filter { $0.status.hasPending }
        guard !pending.isEmpty else { return nil }
        let count = pending.reduce(0) { $0 + $1.status.queuedCount }
        let names = pending.map(\.remoteName).joined(separator: ", ")
        let question: String
        let confirm: String
        switch action {
        case .quit: question = "Quit anyway?"; confirm = "Quit Anyway"
        case .unmount: question = "Unmount anyway?"; confirm = "Unmount Anyway"
        case .installUpdate: question = "Install update anyway?"; confirm = "Install Update Anyway"
        }
        return UploadWarning(
            messageText: "\(count) \(count == 1 ? "file is" : "files are") still uploading to \(names). \(question)",
            informativeText: "Wait for uploads to finish to make sure your files reach the remote.",
            confirmButtonTitle: confirm, waitButtonTitle: "Wait")
    }
}
