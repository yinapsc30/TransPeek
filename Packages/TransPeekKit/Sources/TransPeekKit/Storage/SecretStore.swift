import Foundation
import os
import Security

/// 钥匙串账户名（design.md「持久化」）。
public enum SecretAccount {
    public static let google = "google-api-key"

    public static func llm(_ profileID: UUID) -> String {
        "llm-\(profileID.uuidString)"
    }
}

/// API Key 存储（R8.2、R16.13）。
public protocol SecretStore: Sendable {
    func secret(for account: String) -> String?
    func setSecret(_ value: String?, for account: String) throws
}

public struct SecretStoreError: Error, LocalizedError, Equatable {
    public let status: OSStatus

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "未知错误"
        return "钥匙串操作失败（\(status)）：\(message)"
    }
}

/// 基于 macOS 钥匙串（generic password）的实现。
public struct KeychainStore: SecretStore {
    public let service: String

    public init(service: String = AppIdentity.subsystem) {
        self.service = service
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func secret(for account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let value = String(data: data, encoding: .utf8),
              !value.isEmpty
        else { return nil }
        return value
    }

    /// 传入 `nil` 或空字符串时删除。
    public func setSecret(_ value: String?, for account: String) throws {
        let query = baseQuery(account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else { throw SecretStoreError(status: status) }
            return
        }
        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            add[kSecAttrLabel as String] = "TransPeek (\(account))"
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw SecretStoreError(status: status) }
    }
}

/// 内存实现，用于测试和预览。
public final class InMemorySecretStore: SecretStore {
    private let storage = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    public init(_ initial: [String: String] = [:]) {
        storage.withLock { $0 = initial }
    }

    public func secret(for account: String) -> String? {
        storage.withLock { $0[account] }
    }

    public func setSecret(_ value: String?, for account: String) throws {
        storage.withLock { dict in
            if let value, !value.isEmpty { dict[account] = value } else { dict.removeValue(forKey: account) }
        }
    }
}
