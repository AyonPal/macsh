import AppKit
import MacshCore

/// Bridges HostKeyPrompter (which is sync from background contexts) to NSAlert on the main thread.
final class HostKeyAlertPrompter: HostKeyPrompter {
    func confirm(_ decision: inout HostKeyDecision) {
        let result = onMainSync { () -> Bool in
            let alert = NSAlert()
            alert.messageText = "Trust new host?"
            alert.informativeText = """
                \(decision.host):\(decision.port)

                Fingerprint:
                \(decision.fingerprintSHA256)

                Only trust this host if you recognize the fingerprint.
                """
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Trust")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn
        }
        decision.accepted = result
    }

    func confirmChange(host: String, port: Int, oldFingerprint: String, newFingerprint: String) -> Bool {
        onMainSync { () -> Bool in
            let alert = NSAlert()
            alert.messageText = "Host key CHANGED for \(host):\(port)"
            alert.informativeText = """
                The host key for this server has changed since you last connected.
                This could indicate a man-in-the-middle attack.

                Old fingerprint:
                \(oldFingerprint)

                New fingerprint:
                \(newFingerprint)
                """
            alert.alertStyle = .critical
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: "Trust new key")
            return alert.runModal() == .alertSecondButtonReturn
        }
    }

    private func onMainSync<T>(_ body: () -> T) -> T {
        if Thread.isMainThread { return body() }
        var result: T!
        DispatchQueue.main.sync { result = body() }
        return result
    }
}
