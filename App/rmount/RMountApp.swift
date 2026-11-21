import SwiftUI
import AppKit
import RMountCore

@main
struct RMountApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var menuBar: MenuBarController?
    var loginItemManager: LoginItemManager?
    private var checkingTermination = false
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
            let bundleID = Bundle.main.bundleIdentifier ?? "ai.rmount"
            // Aliases of the names used while the app was called macsh: data under the old
            // bundle id is carried over on first launch, and the old names stay readable.
            let legacyIDs = LegacyNames.legacyBundleIDs(for: bundleID)
            let supportDir = try AppPaths.applicationSupport(bundleID: bundleID, legacyBundleIDs: legacyIDs)
            let store = RemoteStore(directory: supportDir)
            let keychain = KeychainService(serviceName: bundleID, legacyServiceNames: legacyIDs)
            let mounter = Mounter()
            let prefs = UserPreferences(legacyDomains: legacyIDs)
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
            alert.messageText = "RMount failed to start"
            alert.informativeText = String(describing: error)
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Quit")
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let menuBar else { return .terminateNow }
        guard !checkingTermination else { return .terminateLater }
        checkingTermination = true
        Task { @MainActor in
            let shouldQuit = await menuBar.confirmQuit()
            checkingTermination = false
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        menuBar?.manager.shutdownAll()
    }
}
