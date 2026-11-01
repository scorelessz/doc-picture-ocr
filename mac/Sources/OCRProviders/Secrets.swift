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

/// 当前程序的 cdhash。ad-hoc 签名没有稳定身份，这就是它的身份。
public func codeIdentity() -> String {
    var code: SecCode?, sc: SecStaticCode?, info: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code, SecCodeCopyStaticCode(code, [], &sc) == errSecSuccess, let sc,
          SecCodeCopySigningInformation(sc, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let d = (info as? [String: Any])?[kSecCodeInfoUnique as String] as? Data else { return "unknown" }
    return d.map { String(format: "%02x", $0) }.joined()
}

/// 只存本机，不进 iCloud 钥匙串和备份。ocr-cli 和 App 读写同一套条目。
///
/// 这类条目绑定写入者的 cdhash。别的构建读它时系统会弹授权框，kSecUseAuthenticationUIFail 拦不住（实测），
/// 所以不能靠试读判断状态：写入时把 cdhash 记进条目属性，读属性不用解密、不弹框。
public struct KeychainStore: SecretStore {
    public static let defaultService = "com.dococr.provider"
    let service: String, identity: String, granted: UserDefaults

    public init(service: String = KeychainStore.defaultService, identity: String = codeIdentity(), granted: UserDefaults = .standard) {
        self.service = service; self.identity = identity; self.granted = granted
    }

    private func query(_ id: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: id, kSecAttrSynchronizable as String: false]
    }

    private func grantKey(_ id: String) -> String { "keychainGranted.\(service).\(id)" }

    private func attributes(_ id: String) throws -> (date: Date?, writer: String?)? {
        var q = query(id)
        q[kSecReturnAttributes as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        guard st == errSecSuccess else { throw SecretError.keychain(st) }
        let a = out as? [String: Any]
        return (a?[kSecAttrModificationDate as String] as? Date, (a?[kSecAttrGeneric as String] as? Data).map { String(decoding: $0, as: UTF8.self) })
    }

    /// 这个程序写的，或用户授权过这个程序
    private func mayRead(_ a: (date: Date?, writer: String?)?, _ id: String) -> Bool {
        a?.writer == identity || granted.string(forKey: grantKey(id)) == identity
    }

    private func read(_ id: String) throws -> SecretKey? {
        var q = query(id)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        let st = SecItemCopyMatching(q as CFDictionary, &out)
        if st == errSecItemNotFound { return nil }
        if [errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled].contains(st) { throw SecretError.needsReentry }
        guard st == errSecSuccess, let d = out as? Data else { throw SecretError.keychain(st) }
        return SecretKey(String(decoding: d, as: UTF8.self))
    }

    public func load(_ id: String) throws -> SecretKey? {
        guard let a = try attributes(id) else { return nil }
        guard mayRead(a, id) else { throw SecretError.needsReentry }     // 不试读：试读就会弹框
        return try read(id)
    }

    public func loadAuthorizing(_ id: String) throws -> SecretKey? {
        let k = try read(id)
        if k != nil { granted.set(identity, forKey: grantKey(id)) }
        return k
    }

    public func state(_ id: String) throws -> KeyState {
        guard let a = try attributes(id) else { return .none }
        guard mayRead(a, id), let k = try read(id) else { return .needsAuthorization(modified: a.date) }
        return .of(k.value, modified: a.date)
    }

    @discardableResult public func save(_ key: String, for id: String) throws -> Bool {
        let had = try attributes(id) != nil
        try delete(id)
        var q = query(id)
        q[kSecValueData as String] = Data(key.utf8)
        q[kSecAttrGeneric as String] = Data(identity.utf8)
        q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let st = SecItemAdd(q as CFDictionary, nil)
        guard st == errSecSuccess else { throw SecretError.keychain(st) }
        granted.removeObject(forKey: grantKey(id))
        return had
    }

    public func delete(_ id: String) throws {
        let st = SecItemDelete(query(id) as CFDictionary)
        if st == errSecSuccess || st == errSecItemNotFound { return }
        // 别的构建写的条目，这个程序没有删除权限（-25244）。系统的 security 工具不受这个限制。
        guard st == errSecInvalidOwnerEdit else { throw SecretError.cannotDelete(st) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", service, "-a", id]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do {
            try p.run()
            p.waitUntilExit()
        } catch { throw SecretError.cannotDelete(st) }
        guard p.terminationStatus == 0 else { throw SecretError.cannotDelete(st) }
    }
}
#endif
