import Foundation

public enum MountURL {
    public static func webdav(host: String, port: Int, user: String, password: String) -> String {
        let allowed = CharacterSet.urlPasswordAllowed.subtracting(CharacterSet(charactersIn: "@:/"))
        let u = user.addingPercentEncoding(withAllowedCharacters: allowed) ?? user
        let p = password.addingPercentEncoding(withAllowedCharacters: allowed) ?? password
        return "http://\(u):\(p)@\(host):\(port)/"
    }
}
