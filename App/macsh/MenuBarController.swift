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

    // Spinner animation for .starting sessions
    private var spinnerTimer: Timer?
    private var spinnerFrame = 0
    private var sessionMenuItems: [UUID: NSMenuItem] = [:]
    private static let spinnerFrames = ["◐", "◓", "◑", "◒"]

    init(manager: SessionManager, loginItemManager: LoginItemManager, prefs: UserPreferences) {
        self.manager = manager
        self.loginItemManager = loginItemManager
        self.prefs = prefs
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            if let icon = NSImage(named: "MenuBarIcon") {
                icon.isTemplate = true
                icon.size = NSSize(width: 18, height: 18)
                button.image = icon
            } else {
                button.title = "⛬"
            }
        }
        rebuildMenu()
        manager.$sessions
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
    }

    private func rebuildMenu() {
        sessionMenuItems.removeAll()
        let menu = NSMenu()
        if manager.sessions.isEmpty {
            menu.addItem(NSMenuItem(title: "(no remotes)", action: nil, keyEquivalent: ""))
        } else {
            for session in manager.sessions {
                let item = NSMenuItem(title: title(for: session), action: #selector(toggleMount(_:)), keyEquivalent: "")
                sessionMenuItems[session.id] = item
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
        let checkUpdates = NSMenuItem(title: "Check for updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdates.target = self
        menu.addItem(checkUpdates)
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
        syncSpinner()
    }

    // MARK: - Spinner

    private func syncSpinner() {
        let hasStarting = manager.sessions.contains { if case .starting = $0.status { return true }; return false }
        if hasStarting {
            if spinnerTimer == nil {
                let t = Timer(timeInterval: 0.15, repeats: true) { [weak self] _ in
                    self?.tickSpinner()
                }
                RunLoop.main.add(t, forMode: .common)
                spinnerTimer = t
            }
        } else {
            spinnerTimer?.invalidate()
            spinnerTimer = nil
            // Flush final titles into the live menu items — the visible NSMenu may still
            // be the old instance (NSMenu tracks in its own run loop mode and ignores
            // statusItem.menu reassignment until closed).
            for session in manager.sessions {
                sessionMenuItems[session.id]?.title = title(for: session)
            }
        }
    }

    private func tickSpinner() {
        spinnerFrame = (spinnerFrame + 1) % Self.spinnerFrames.count
        let dot = Self.spinnerFrames[spinnerFrame]
        for session in manager.sessions {
            if case .starting = session.status {
                sessionMenuItems[session.id]?.title = "\(dot) \(session.remote.name)"
            } else {
                sessionMenuItems[session.id]?.title = title(for: session)
            }
        }
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

    @objc private func checkForUpdates() {
        let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let url = URL(string: "https://api.github.com/repos/AyonPal/macsh/releases/latest")!
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        URLSession.shared.dataTask(with: req) { data, _, error in
            Task { @MainActor in
                if let error {
                    Self.showUpdateAlert(title: "Couldn't check for updates", message: error.localizedDescription, style: .warning)
                    return
                }
                guard let data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let tag = json["tag_name"] as? String else {
                    Self.showUpdateAlert(title: "Couldn't check for updates", message: "Unexpected response from GitHub.", style: .warning)
                    return
                }
                let latest = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
                let pageURL = (json["html_url"] as? String).flatMap(URL.init(string:))
                    ?? URL(string: "https://github.com/AyonPal/macsh/releases/latest")!
                if Self.compareVersions(current, latest) < 0 {
                    let alert = NSAlert()
                    alert.messageText = "Update available"
                    alert.informativeText = "You're on \(current). \(latest) is out."
                    alert.addButton(withTitle: "Open release page")
                    alert.addButton(withTitle: "Later")
                    if alert.runModal() == .alertFirstButtonReturn {
                        NSWorkspace.shared.open(pageURL)
                    }
                } else {
                    Self.showUpdateAlert(title: "You're up to date", message: "macsh \(current) is the latest version.", style: .informational)
                }
            }
        }.resume()
    }

    private static func showUpdateAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.runModal()
    }

    /// Compares dotted numeric version strings ("0.1.2" vs "0.1.10"). Non-numeric
    /// suffixes are ignored. Returns -1, 0, or 1.
    private static func compareVersions(_ a: String, _ b: String) -> Int {
        let parse: (String) -> [Int] = { s in
            s.split(separator: ".").map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let lhs = parse(a), rhs = parse(b)
        for i in 0..<max(lhs.count, rhs.count) {
            let l = i < lhs.count ? lhs[i] : 0
            let r = i < rhs.count ? rhs[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
