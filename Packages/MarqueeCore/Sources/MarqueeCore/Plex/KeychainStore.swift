#if canImport(Security)
import Foundation
import Security

/// Secrets in the Keychain: the account token, and encoded servers since they carry access tokens.
///
/// Items stay on this device (never synced or restored to another phone) and are readable after the
/// first unlock, so playback reporting keeps working with the screen locked.
public struct KeychainStore: Sendable {
    public let service: String

    public init(service: String = "com.nphil.marquee") {
        self.service = service
    }

    public func data(for key: String) throws -> Data? {
        var query = baseQuery(key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess: return result as? Data
        case errSecItemNotFound: return nil
        default: throw KeychainError(status: status)
        }
    }

    /// Stores `data` under `key`; nil removes it.
    public func setData(_ data: Data?, for key: String) throws {
        guard let data else {
            let status = SecItemDelete(baseQuery(key) as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
            return
        }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        var status = SecItemUpdate(baseQuery(key) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(baseQuery(key).merging(attributes) { $1 } as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError(status: status) }
    }

    public func string(for key: String) throws -> String? {
        try data(for: key).map { String(decoding: $0, as: UTF8.self) }
    }

    /// Stores `value` under `key`; nil removes it.
    public func setString(_ value: String?, for key: String) throws {
        try setData(value.map { Data($0.utf8) }, for: key)
    }

    private func baseQuery(_ key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

public struct KeychainError: Error, Sendable, Equatable {
    public let status: OSStatus
}
#endif
