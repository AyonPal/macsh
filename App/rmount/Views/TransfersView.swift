import SwiftUI
import RMountCore

struct TransfersView: View {
    final class Navigator: ObservableObject {
        @Published var remoteID: UUID?
    }

    @ObservedObject var manager: SessionManager
    @ObservedObject var navigator: Navigator

    private var visibleSessions: [RemoteSession] {
        manager.sessions.filter { session in
            if let id = navigator.remoteID { return session.id == id }
            guard let status = manager.uploadStatus[session.id] else { return false }
            return status.hasPending || status.isStale
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Remote", selection: $navigator.remoteID) {
                Text("All remotes").tag(nil as UUID?)
                ForEach(manager.sessions) { session in
                    Text(session.remote.name).tag(Optional(session.id))
                }
            }
            if visibleSessions.isEmpty {
                idle
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(visibleSessions) { session in
                            remoteSection(session)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(minWidth: 380, minHeight: 200)
    }

    private var idle: some View {
        Text("No uploads in progress")
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func remoteSection(_ session: RemoteSession) -> some View {
        let status = manager.uploadStatus[session.id] ?? UploadStatus()
        return GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if status.isStale {
                    Label("Waiting for rclone…", systemImage: "clock")
                        .foregroundStyle(.secondary)
                }
                if status.hasPending {
                    Text(status.summary.text).font(.subheadline)
                    ForEach(Array(status.transfers.enumerated()), id: \.offset) { _, transfer in
                        TransferRow(transfer: transfer, isStale: status.isStale)
                    }
                } else if !status.isStale {
                    Text("No uploads in progress").foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(4)
        } label: {
            Text(session.remote.name).font(.headline)
        }
    }
}

private struct TransferRow: View {
    let transfer: TransferProgress
    let isStale: Bool

    private var stateText: String {
        switch transfer.state {
        case .queued: return "Queued"
        case .uploading: return "Uploading"
        case .finishing: return "Finishing…"
        case .retrying: return "Retrying…"
        }
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: value, countStyle: .file)
    }

    private var byteText: String {
        guard let total = transfer.totalBytes else { return "Unknown size" }
        guard let done = transfer.bytesDone else { return bytes(total) }
        return "\(bytes(done)) of \(bytes(total))"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(alignment: .firstTextBaseline) {
                Text((transfer.path as NSString).lastPathComponent)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .help(transfer.path)
                Spacer()
                Text(stateText).foregroundStyle(.secondary)
            }
            if (transfer.path as NSString).deletingLastPathComponent != "" {
                Text(transfer.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            if let fraction = transfer.fraction {
                ProgressView(value: fraction)
            } else {
                // No percentage is available while rclone is still queuing a file.
                ProgressView(value: 0)
            }
            HStack {
                Text(byteText)
                Spacer()
                if !isStale, let speed = transfer.speed, speed.isFinite, speed > 0 {
                    Text("\(bytes(Int64(min(speed, Double(Int64.max / 2)))))/s")
                }
                if !isStale, transfer.state != .finishing {
                    if let eta = transfer.eta, eta.isFinite, eta >= 0 {
                        Text(Duration.seconds(min(eta, Double(Int64.max / 2))).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .abbreviated)) + " left")
                    } else {
                        Text("Calculating…")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
