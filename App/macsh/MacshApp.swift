import SwiftUI
import AppKit
import MacshCore

@main
struct MacshApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarController?
    var loginItemManager: LoginItemManager?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // `kill`/`pkill`, logout and shell Ctrl-C send SIGTERM/SIGINT. Without a handler the
        // process dies without running applicationWillTerminate, leaving dead mounts behind
        // ("Server connections interrupted"). Route them through the normal quit path.
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { NSApp.terminate(nil) }
            src.resume()
            signalSources.append(src)
        }
        do {
            let bundleID = Bundle.main.bundleIdentifier ?? "ai.macsh"
            let supportDir = try AppPaths.applicationSupport(bundleID: bundleID)
            let store = RemoteStore(directory: supportDir)
            let keychain = KeychainService(serviceName: bundleID)
            let mounter = Mounter()
            let prefs = UserPreferences()
            let binary = try RcloneBinary.resolve(prefs: prefs)
            let knownHosts = supportDir.appendingPathComponent("known_hosts").path
            let prompter = HostKeyAlertPrompter()
            let verifier = HostKeyVerifier(knownHostsPath: knownHosts, prompter: prompter)
            let manager = SessionManager(
                store: store,
                keychain: keychain,
                mounter: mounter,
                logsDir: supportDir.appendingPathComponent("logs", isDirectory: true),
                rcloneBinary: binary,
                hostKeyVerifier: verifier
            )
            try manager.reload()
            loginItemManager = LoginItemManager()
            menuBar = MenuBarController(manager: manager, loginItemManager: loginItemManager!, prefs: prefs)
            manager.autoMountAll()
        } catch {
            let alert = NSAlert()
            alert.messageText = "macsh failed to start"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.manager.shutdownAll()
    }
}
