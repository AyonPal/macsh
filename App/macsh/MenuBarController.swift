import AppKit
import SwiftUI
import MacshCore
import Combine

@MainActor
final class MenuBarController {
    let manager: SessionManager
    let loginItemManager: LoginItemManager
    let prefs: UserPreferences
    private var statusItem: NSStatusItem!
    private var cancellables = Set<AnyCancellable>()
    private var addWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var editWindows: [UUID: NSWindow] = [:]
    private var logWindows: [UUID: NSWindow] = [:]

    init(manager: SessionManager, loginItemManager: LoginItemManager, prefs: UserPreferences) {
        self.manager = manager
        self.loginItemManager = loginItemManager
        self.prefs = prefs
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "⛬"
        rebuildMenu()
        manager.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        let menu = NSMenu()
        if manager.sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "(no remotes)", action: nil, keyEquivalent: ""))
        } else {
            for session in manager.sessions {
                let item = NSMenuItem(title: title(for: session), action: #selector(toggleMount(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = session.id
                let submenu = NSMenu()
                submenu.autoenablesItems = false
                let mountToggle = NSMenuItem(
                    title: isMounted(session) ? "Unmount" : "Mount",
                    action: #selector(toggleMount(_:)),
                    keyEquivalent: ""
                )
                mountToggle.target = self
                mountToggle.representedObject = session.id
                submenu.addItem(mountToggle)
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
            }
        }
        menu.addItem(NSMenuItem.separator())
        let add = NSMenuItem(title: "Add remote…", action: #selector(showAdd), keyEquivalent: "n")
        add.target = self
        menu.addItem(add)
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
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
                case .mounted: try manager.unmount(remoteID: id)
                default: try manager.mount(remoteID: id)
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
        do { try manager.delete(id) }
        catch { NSAlert(error: error).runModal() }
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

    @objc private func showLog(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID else { return }
        let url = manager.logURL(for: id)
        if logWindows[id] == nil {
            let host = NSHostingController(rootView: LogWindow(logURL: url))
            let win = NSWindow(contentViewController: host)
            win.title = "macsh log: \(id.uuidString.prefix(8))"
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

    @objc private func showSettings() {
        if settingsWindow == nil {
            let view = SettingsView(loginItemManager: loginItemManager, prefs: prefs)
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
}
