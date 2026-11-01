import Foundation
import OCRCore

// 联网总开关和服务商选中状态。默认全关，由 GuardedTransport 强制执行。

/// 总开关。关掉立即生效：观察者取消进行中的请求。
public final class NetworkSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool
    private var observers: [@Sendable () -> Void] = []

    public init(allowed: Bool = false) { on = allowed }

    public var allowed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return on
    }

    public func set(allowed: Bool) {
        lock.lock()
        let changed = on != allowed
        on = allowed
        let obs = observers
        lock.unlock()
        guard changed else { return }
        Log.shared.info("network_switch", ["allowed": .b(allowed)])
        if !allowed { obs.forEach { $0() } }
    }

    func onDisable(_ f: @escaping @Sendable () -> Void) {
        lock.lock()
        observers.append(f)
        lock.unlock()
    }
}

/// 用户亲自选中的服务商。预置只是可选列表，默认一家都不选；有 key 也不算选中。
public final class ProviderSelection: @unchecked Sendable {
    private let lock = NSLock()
    private var ids: Set<String> = []

    public init() {}

    public func select(_ id: String) {
        lock.lock()
        ids.insert(id)
        lock.unlock()
    }

    public func deselect(_ id: String) {
        lock.lock()
        ids.remove(id)
        lock.unlock()
    }

    public func isSelected(_ id: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return ids.contains(id)
    }
}
