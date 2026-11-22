import AppKit
import SwiftUI
import RMountCore
import Combine

@MainActor
final class MenuBarController {
    let manager: SessionManager
    let loginItemManager: LoginItemManager
    let prefs: UserPreferences
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var addWindow: NSWindow?
    private var importWindow: NSWindow?
    private var transfersWindow: NSWindow?
    private let transfersNavigator = TransfersView.Navigator()
    private var settingsWindow: NSWindow?
    private let settingsNavigator = SettingsView.Navigator()
    private var editWindows: [UUID: NSWindow] = [:]
    private var logWindows: [UUID: NSWindow] = [:]
    private let updater: UpdateController

    init(manager: SessionManager, loginItemManager: LoginItemManager, prefs: UserPreferences) {
        self.manager = manager
        self.loginItemManager = loginItemManager
        self.prefs = prefs
        self.updater = UpdateController(prefs: prefs, manager: manager)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        rebuildMenu()
        manager.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        manager.$uploadStatus
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        updater.checkInBackgroundIfDue()
    }

    private func rebuildMenu() {
        if let button = statusItem.button {
            let name = manager.pendingUploads().isEmpty ? "MenuBarIcon" : "MenuBarIconUploading"
            if let icon = NSImage(named: name) {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                button.title = "⛬"
            }
        }
        let menu = NSMenu()
        if manager.sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "(no remotes)", action: nil, keyEquivalent: ""))
        } else {
            for session in manager.sessions {
                let item = NSMenuItem(
                    title: title(for: session),
                    action: isMounted(session) ? #selector(openInFinder(_:)) : #selector(toggleMount(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = session.id
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                if case .mounted = session.status {
                    let open = NSMenuItem(title: "Open in Finder", action: #selector(openInFinder(_:)), keyEquivalent: "")
                    open.target = self
                    open.representedObject = session.id
                    submenu.addItem(open)
                    submenu.addItem(NSMenuItem.separator())
                }
                let mountToggle = NSMenuItem(
                    title: isMounted(session) ? "Unmount" : "Mount",
                    action: #selector(toggleMount(_:)),
                    keyEquivalent: ""
                )
                mountToggle.target = self
                mountToggle.representedObject = session.id
                submenu.addItem(mountToggle)
                let transfers = NSMenuItem(title: "Transfers…", action: #selector(showTransfers(_:)), keyEquivalent: "")
                transfers.target = self
                transfers.representedObject = session.id
                submenu.addItem(transfers)
                let viewLog = NSMenuItem(title: "View log…", action: #selector(showLog(_:)), keyEquivalent: "")
                viewLog.target = self
                viewLog.representedObject = session.id
                submenu.addItem(viewLog)
                let edit = NSMenuItem(title: "Edit…", action: #selector(editRemote(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = session.id
                edit.isEnabled = !isMounted(session)
                submenu.addItem(edit)
                let delete = NSMenuItem(title: "Delete remote", action: #selector(deleteRemote(_:)), keyEquivalent: "")
                delete.target = self
                delete.representedObject = session.id
                delete.isEnabled = !isMounted(session)
                submenu.addItem(delete)
                item.submenu = submenu
                menu.addItem(item)
                if isMounted(session), let status = manager.uploadStatus[session.id], status.hasPending {
                    let progress = NSMenuItem(title: status.menuText, action: #selector(showTransfers(_:)), keyEquivalent: "")
                    progress.target = self
                    progress.representedObject = session.id
                    progress.indentationLevel = 1
                    menu.addItem(progress)
                }
            }
        }
        menu.addItem(NSMenuItem.separator())
        let transfers = NSMenuItem(title: "Transfers…", action: #selector(showTransfers(_:)), keyEquivalent: "")
        transfers.target = self
        menu.addItem(transfers)
        let add = NSMenuItem(title: "Add remote…", action: #selector(showAdd), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)
        let importItem = NSMenuItem(title: "Import from rclone…", action: #selector(showImport), keyEquivalent: "")
        importItem.target = self
        menu.addItem(importItem)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let about = NSMenuItem(title: "About RMount", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        let checkUpdates = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    func confirmQuit() async -> Bool {
        if updater.isRelaunching { return true }
        await manager.refreshUploadStatus()
        return UploadSafetyAlert.confirm(
            UploadGuard.warning(for: .quit, uploads: manager.pendingUploads())
        )
    }

    private func isMounted(_ session: RemoteSession) -> Bool {
        if case .mounted = session.status { return true }
        return false
    }

    private func title(for session: RemoteSession) -> String {
        let dot: String
        switch session.status {
        case .idle: dot = "○"
        case .starting: dot = "◐"
        case .stopping: dot = "◑"
        case .mounted: dot = "●"
        case .failed: dot = "✕"
        }
        return "\(dot) \(session.remote.name)"
    }

    @objc private func toggleMount(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = manager.sessions.first(where: { $0.id == id }) else { return }
        Task { @MainActor in
            do {
                switch session.status {
                case .starting, .stopping: return        // already working on it
                case .mounted:
                    await manager.refreshUploadStatus(remoteID: id)
                    let uploads = manager.uploadStatus[id].map { [(remoteName: session.remote.name, status: $0)] } ?? []
                    guard UploadSafetyAlert.confirm(UploadGuard.warning(for: .unmount, uploads: uploads)) else { return }
                    try await manager.unmount(remoteID: id)
                default: try await manager.mount(remoteID: id)
                }
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    @objc private func deleteRemote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = manager.sessions.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete remote \(session.remote.name)?"
        alert.informativeText = "This removes the remote, its credentials in Keychain, and unmounts it if mounted."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            await manager.refreshUploadStatus(remoteID: id)
            let uploads = manager.uploadStatus[id].map { [(remoteName: session.remote.name, status: $0)] } ?? []
            guard UploadSafetyAlert.confirm(UploadGuard.warning(for: .unmount, uploads: uploads)) else { return }
            do { try manager.delete(id) }
            catch { NSAlert(error: error).runModal() }
        }
    }

    @objc private func editRemote(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = manager.sessions.first(where: { $0.id == id }) else { return }
        if isMounted(session) { return }
        if editWindows[id] == nil {
            let view = AddRemoteView(manager: manager, prefs: prefs, editing: session.remote)
            let host = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: host)
            win.title = "Edit \(session.remote.name)"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            // Drop the entry once the user closes the window so a fresh one is built
            // with current data on the next Edit…
            let token = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: win,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.editWindows.removeValue(forKey: id) }
            }
            objc_setAssociatedObject(win, "editObs", token, .OBJC_ASSOCIATION_RETAIN)
            editWindows[id] = win
        }
        Self.present(editWindows[id])
    }

    @objc private func openInFinder(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let session = manager.sessions.first(where: { $0.id == id }),
              case .mounted(let path) = session.status else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    @objc private func showLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let url = manager.logURL(for: id)
        if logWindows[id] == nil {
            let host = NSHostingController(rootView: LogWindow(logURL: url))
            let win = NSWindow(contentViewController: host)
            win.title = "RMount log: \(id.uuidString.prefix(8))"
            win.styleMask = [.titled, .closable, .resizable]
            logWindows[id] = win
        }
        Self.present(logWindows[id])
    }

    @objc private func showAdd() {
        if addWindow == nil {
            let view = AddRemoteView(manager: manager, prefs: prefs)
            let host = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: host)
            win.title = "Add remote"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            addWindow = win
        }
        Self.present(addWindow)
    }

    @objc private func showImport() {
        // Rebuilt each time so it re-reads rclone.conf and starts with a clean selection.
        let view = ImportRemotesView(manager: manager, prefs: prefs)
        let host = NSHostingController(rootView: view)
        let win = NSWindow(contentViewController: host)
        win.title = "Import from rclone"
        win.styleMask = [.titled, .closable]
        win.isReleasedWhenClosed = false
        importWindow = win
        Self.present(importWindow)
    }

    @objc private func showTransfers(_ sender: NSMenuItem) {
        transfersNavigator.remoteID = sender.representedObject as? UUID
        if transfersWindow == nil {
            let view = TransfersView(manager: manager, navigator: transfersNavigator)
            let win = NSWindow(contentViewController: NSHostingController(rootView: view))
            win.title = "Transfers"
            win.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            win.isReleasedWhenClosed = false
            win.setContentSize(NSSize(width: 580, height: 420))
            win.contentMinSize = NSSize(width: 420, height: 240)
            transfersWindow = win
        }
        Self.present(transfersWindow)
    }

    @objc private func showSettings() {
        openSettings(tab: .general)
    }

    @objc private func showAbout() {
        openSettings(tab: .about)
    }

    private func openSettings(tab: SettingsView.Tab) {
        settingsNavigator.tab = tab
        if settingsWindow == nil {
            let view = SettingsView(navigator: settingsNavigator, loginItemManager: loginItemManager, prefs: prefs, onCheckForUpdates: { [weak self] in self?.updater.checkNow() })
            let host = NSHostingController(rootView: view)
            let win = NSWindow(contentViewController: host)
            win.title = "Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            settingsWindow = win
        }
        Self.present(settingsWindow)
    }

    /// Centers a cached window before showing it, so it doesn't reopen at the
    /// last drag position (which can land off-screen on a smaller display).
    /// `layoutIfNeeded` forces SwiftUI to size its content first; otherwise
    /// `center()` runs against the previous frame.
    private static func present(_ window: NSWindow?) {
        guard let win = window else { return }
        win.contentView?.layoutSubtreeIfNeeded()
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        updater.checkNow()
    }
}
