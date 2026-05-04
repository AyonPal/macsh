import Foundation

public enum SessionStatus: Equatable {
    case idle
    case starting
    case mounted(at: String)
    case failed(reason: String)
}
