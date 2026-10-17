import AppKit
import MacshCore

/// Drives "Check for updates": asks GitHub for the newest release of the selected channel,
/// offers it, and (on request) downloads, installs and relaunches. Logic lives in MacshCore
/// (`UpdateChecker`, `UpdateInstaller`); this class is only the alerts and a progress window.
@MainActor
final class UpdateController {
    private let prefs: UserPreferences
    private let checker = UpdateChecker()
    private var busy = false
    private var progressWindow: NSWindow?
    private var progressLabel: NSTextField?

    init(prefs: UserPreferences) {
        self.prefs = prefs
    }

    /// At launch: checks silently about once a day and only speaks up when there is an update.
    func checkInBackgroundIfDue() {
        guard prefs.updateCheckDue() else { return }
        Task { await run(userInitiated: false) }
    }

    func checkNow() {
        Task { await run(userInitiated: true) }
    }

    private func run(userInitiated: Bool) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let build = BuildInfo.current
        let channel = prefs.updateChannel
        do {
            let result = try await checker.check(channel: channel, build: build)
            prefs.lastUpdateCheck = Date()
            switch result {
            case .upToDate(let current):
                if userInitiated {
                    Self.alert("You're up to date", "macsh \(current) is the latest on the \(channel.displayName.lowercased()) channel.", .informational)
                }
            case .available(let update):
                if !userInitiated && prefs.skippedUpdateTag == update.release.tag { return }
                await offer(update, build: build, allowSkip: !userInitiated)
            }
        } catch {
            if userInitiated {
                Self.alert("Couldn't check for updates", error.localizedDescription, .warning)
            }
        }
    }

    private func offer(_ update: AvailableUpdate, build: BuildInfo, allowSkip: Bool) async {
        let running = build.isDevBuild ? "v\(build.version) (local build)" : "v\(build.version) (\(build.shortSHA))"
        let alert = NSAlert()
        alert.messageText = "Update available"
        var text = "You're on \(running).\n\(update.label) is available on the \(update.channel.displayName.lowercased()) channel."
        let notes = update.release.notesExcerpt()
        if !notes.isEmpty { text += "\n\n\(notes)" }
        text += "\n\nInstalling quits macsh (mounted remotes are unmounted) and reopens the new version."
        alert.informativeText = text
        alert.addButton(withTitle: "Install and relaunch")
        alert.addButton(withTitle: "Release notes")
        alert.addButton(withTitle: "Later")
        if allowSkip { alert.addButton(withTitle: "Skip this version") }
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            await install(update)
        case .alertSecondButtonReturn:
            if let url = update.release.htmlURL { NSWorkspace.shared.open(url) }
        case .alertThirdButtonReturn:
            break
        default:
            prefs.skippedUpdateTag = update.release.tag
        }
    }

    private func install(_ update: AvailableUpdate) async {
        showProgress("Downloading \(update.label)…")
        let work = FileManager.default.temporaryDirectory.appendingPathComponent("macsh-update-\(UUID().uuidString)")
        defer {
            hideProgress()
            try? FileManager.default.removeItem(at: work)
        }
        do {
            let dmg = try await UpdateInstaller.download(update.asset, to: work)
            progressLabel?.stringValue = "Installing…"
            let app = Bundle.main.bundleURL
            let digest = update.asset.digest
            try await Task.detached(priority: .userInitiated) {
                try UpdateInstaller.install(dmg: dmg, expectedDigest: digest, over: app)
            }.value
            hideProgress()
            try UpdateInstaller.relaunchProcess(appURL: app).run()
            NSApp.terminate(nil)
        } catch {
            hideProgress()
            Self.alert("Update failed", error.localizedDescription, .warning)
        }
    }

    // MARK: - Small UI helpers

    private func showProgress(_ text: String) {
        let label = NSTextField(labelWithString: text)
        let spinner = NSProgressIndicator()
        spinner.style = .spinning
        spinner.isIndeterminate = true
        spinner.startAnimation(nil)
        let stack = NSStackView(views: [spinner, label])
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 70),
                           styleMask: [.titled], backing: .buffered, defer: false)
        win.contentView = stack
        win.title = "Updating macsh"
        win.styleMask = [.titled]
        win.isReleasedWhenClosed = false
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        progressWindow = win
        progressLabel = label
    }

    private func hideProgress() {
        progressWindow?.orderOut(nil)
        progressWindow = nil
        progressLabel = nil
    }

    private static func alert(_ title: String, _ message: String, _ style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }
}
