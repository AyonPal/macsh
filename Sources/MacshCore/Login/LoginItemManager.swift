import Foundation
import ServiceManagement

public enum LoginItemError: Error {
    case registrationFailed(Error)
}

@MainActor
public final class LoginItemManager {
    public init() {}

    public var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    public func setEnabled(_ enabled: Bool) throws {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            throw LoginItemError.registrationFailed(error)
        }
    }
}
