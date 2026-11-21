import AppKit
import RMountCore

@MainActor
enum UploadSafetyAlert {
    static func confirm(_ warning: UploadWarning?) -> Bool {
        guard let warning else { return true }
        let alert = NSAlert()
        alert.messageText = warning.messageText
        alert.informativeText = warning.informativeText
        alert.alertStyle = .warning
        alert.addButton(withTitle: warning.waitButtonTitle)
        alert.addButton(withTitle: warning.confirmButtonTitle)
        return alert.runModal() == .alertSecondButtonReturn
    }
}
