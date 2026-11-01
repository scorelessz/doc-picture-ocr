import Foundation

// Key 的包装类型：打印和日志里只有 <redacted>，不实现 Encodable。

public struct SecretKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) { self.value = value }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

public protocol SecretStore: Sendable {
    func load(_ providerID: String) throws -> SecretKey?
    func save(_ key: String, for providerID: String) throws
    func delete(_ providerID: String) throws
}

/// 单测用
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]

    public init() {}

    public func load(_ id: String) -> SecretKey? {
        lock.lock()
        defer { lock.unlock() }
        return keys[id].map(SecretKey.init)
    }

    public func save(_ key: String, for id: String) {
        lock.lock()
        keys[id] = key
        lock.unlock()
    }

    public func delete(_ id: String) {
        lock.lock()
        keys[id] = nil
        lock.unlock()
    }
}

#if canImport(Security)
import Security

public enum SecretError: Error, Equatable {
    case keychain(Int32)
}

/// 只存本机，不进 iCloud 钥匙串和备份。
public struct KeychainStore: SecretStore {
    public static let defaultService = "com.dococr.provider"
    let service: String

    public init(service: String = KeychainStore.defaultService) { self.service = service }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }

    public func load(_ id: String) throws -> SecretKey? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess, let d = out as? Data else { throw SecretError.keychain(st) }
        return SecretKey(String(decoding: d, as: UTF8.self))
    }

    public func save(_ key: String, for id: String) throws {
        try delete(id)
        var q = query(id)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw SecretError.keychain(st) }
    }

    public func delete(_ id: String) throws {
        let st = SecItemDelete(query(id) as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw SecretError.keychain(st) }
    }
}
#endif
