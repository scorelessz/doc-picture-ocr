import Foundation

// Key 的包装类型：打印和日志里只有 <redacted>，不实现 Encodable。

public struct SecretKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) { self.value = value }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// Key 的状态。永远不含明文，只有前 4 位和长度。
public enum KeyState: Sendable, Equatable {
    case none
    case readable(prefix: String, length: Int, modified: Date?)
    case needsAuthorization(modified: Date?)      // 条目在，这个签名读不了

    static func of(_ key: String, modified: Date?) -> KeyState { .readable(prefix: String(key.prefix(4)), length: key.count, modified: modified) }
}

public protocol SecretStore: Sendable {
    /// 不弹系统授权框；读不了抛 SecretError.needsReentry
    func load(_ providerID: String) throws -> SecretKey?
    /// 用户点了「授权读取」才调用，会弹系统授权框
    func loadAuthorizing(_ providerID: String) throws -> SecretKey?
    func state(_ providerID: String) throws -> KeyState
    /// 已有条目时删除重建，当前签名读不了也一样。返回是否覆盖了旧条目。
    @discardableResult func save(_ key: String, for providerID: String) throws -> Bool
    func delete(_ providerID: String) throws
}

public enum SecretError: Error, Equatable, CustomStringConvertible {
    case keychain(Int32)
    /// ad-hoc 签名没有稳定身份，换一个构建就读不了旧条目
    case needsReentry
    case cannotDelete(Int32)

    public var description: String {
        switch self {
        case .keychain(let s): return "Keychain 错误 \(s)"
        case .needsReentry: return "这个 Key 已保存，但当前版本的 App 没有读取权限"
        case .cannotDelete(let s):
            return "删不掉旧条目（错误 \(s)）。请打开「钥匙串访问」，搜索 com.dococr.provider，删除这一条后再保存。"
        }
    }
}

/// 单测用。locked 模拟「条目在、这个签名读不了」，undeletable 模拟删不掉。
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [String: String] = [:]
    public var locked: Set<String> = [], undeletable: Set<String> = []
    private var times: [String: Date] = [:]

    public init() {}

    public func load(_ id: String) throws -> SecretKey? {
        lock.lock()
        defer { lock.unlock() }
        if locked.contains(id) { throw SecretError.needsReentry }
        return keys[id].map(SecretKey.init)
    }

    public func loadAuthorizing(_ id: String) -> SecretKey? {
        lock.lock()
        defer { lock.unlock() }
        locked.remove(id)
        return keys[id].map(SecretKey.init)
    }

    public func state(_ id: String) -> KeyState {
        lock.lock()
        defer { lock.unlock() }
        guard let k = keys[id] else { return .none }
        return locked.contains(id) ? .needsAuthorization(modified: times[id]) : .of(k, modified: times[id])
    }

    @discardableResult public func save(_ key: String, for id: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if undeletable.contains(id) { throw SecretError.cannotDelete(-25244) }
        let had = keys[id] != nil
        keys[id] = key
        times[id] = Date()
        locked.remove(id)
        return had
    }

    public func delete(_ id: String) throws {
        lock.lock()
        defer { lock.unlock() }
        if undeletable.contains(id) { throw SecretError.cannotDelete(-25244) }
        keys[id] = nil
        locked.remove(id)
    }
}

#if canImport(Security)
import Security

/// 只存本机，不进 iCloud 钥匙串和备份。ocr-cli 和 App 读写同一套条目。
public struct KeychainStore: SecretStore {
    public static let defaultService = "com.dococr.provider"
    let service: String

    public init(service: String = KeychainStore.defaultService) { self.service = service }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }

    private func read(_ id: String, ui: Bool) throws -> SecretKey? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !ui { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(st) { throw SecretError.needsReentry }
        guard st == errSecSuccess, let d = out as? Data else { throw SecretError.keychain(st) }
        return SecretKey(String(decoding: d, as: UTF8.self))
    }

    public func load(_ id: String) throws -> SecretKey? { try read(id, ui: false) }
    public func loadAuthorizing(_ id: String) throws -> SecretKey? { try read(id, ui: true) }

    /// 属性不需要解密，查它不会弹框
    private func modified(_ id: String) throws -> (exists: Bool, date: Date?) {
        var q = query(id)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return (false, nil) }
        guard st == errSecSuccess else { throw SecretError.keychain(st) }
        return (true, (out as? [String: Any])?[kSecAttrModificationDate as String] as? Date)
    }

    public func state(_ id: String) throws -> KeyState {
        let m = try modified(id)
        guard m.exists else { return .none }
        do {
            guard let k = try load(id) else { return .none }
            return .of(k.value, modified: m.date)
        } catch SecretError.needsReentry {
            return .needsAuthorization(modified: m.date)
        }
    }

    @discardableResult public func save(_ key: String, for id: String) throws -> Bool {
        let had = try modified(id).exists
        try delete(id)
        var q = query(id)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw SecretError.keychain(st) }
        return had
    }

    public func delete(_ id: String) throws {
        var q = query(id)
        q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail
        let st = SecItemDelete(q as CFDictionary)
        guard st == errSecSuccess || st == errSecItemNotFound else { throw SecretError.cannotDelete(st) }
    }
}
#endif
