import Foundation
import Security

public enum SecretKind: String {
    case password
    case keyPassphrase
    case privateKey
    case localServePassword
    case s3AccessKeyID
    case s3SecretAccessKey
}

public enum KeychainError: Error, Equatable {
    case osStatus(OSStatus)
    case decodingFailed
}

public final class KeychainService {
    private let serviceName: String

    public init(serviceName: String) {
        self.serviceName = serviceName
    }

    private func account(_ id: UUID, _ kind: SecretKind) -> String {
        "\(id.uuidString):\(kind.rawValue)"
    }

    private func baseQuery(_ id: UUID, _ kind: SecretKind) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: serviceName,
            kSecAttrAccount as String: account(id, kind),
        ]
    }

    public func set(remoteID: UUID, kind: SecretKind, value: String) throws {
        guard let data = value.data(using: .utf8) else { throw KeychainError.decodingFailed }
        var query = baseQuery(remoteID, kind)
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        if status == errSecSuccess {
            let attrs: [String: Any] = [kSecValueData as String: data]
            let updateStatus = SecItemUpdate(query as CFDictionary, attrs as CFDictionary)
            guard updateStatus == errSecSuccess else { throw KeychainError.osStatus(updateStatus) }
        } else if status == errSecItemNotFound {
            query[kSecValueData as String] = data
            let addStatus = SecItemAdd(query as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.osStatus(addStatus) }
        } else {
            throw KeychainError.osStatus(status)
        }
    }

    public func get(remoteID: UUID, kind: SecretKind) throws -> String? {
        var query = baseQuery(remoteID, kind)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.osStatus(status) }
        guard let data = item as? Data, let str = String(data: data, encoding: .utf8) else {
            throw KeychainError.decodingFailed
        }
        return str
    }

    public func delete(remoteID: UUID, kind: SecretKind) throws {
        let query = baseQuery(remoteID, kind)
        let status = SecItemDelete(query as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError.osStatus(status)
    }
}
