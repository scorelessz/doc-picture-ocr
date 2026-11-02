#if canImport(CryptoKit)
import Foundation
import OCRCore

// 在线请求的并发控制。一家服务商、一次任务一个限流器；只会降并发，绝不换家。

public enum OnlineJobs {
    public static let `default` = 3
    public static let range = 1...8

    public static func clamp(_ n: Int) -> Int { min(range.upperBound, max(range.lowerBound, n)) }
}

public actor ConcurrencyLimiter {
    public private(set) var limit: Int
    private var active = 0, consecutive429 = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    static let lowerAfter = 2

    public init(limit: Int) { self.limit = OnlineJobs.clamp(limit) }

    public func acquire() async {
        if active < limit, waiters.isEmpty {
            active += 1
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    public func release() {
        active -= 1
        pump()
    }

    private func pump() {
        while active < limit, !waiters.isEmpty {
            active += 1
            waiters.removeFirst().resume()
        }
    }

    /// 连续被限流就降一档，返回当前并发数
    @discardableResult public func rateLimited() -> Int {
        consecutive429 += 1
        if consecutive429 >= Self.lowerAfter, limit > 1 {
            limit -= 1
            consecutive429 = 0
        }
        return limit
    }

    public func succeeded() { consecutive429 = 0 }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0

    func next() -> Int {
        lock.lock()
        defer { lock.unlock() }
        n += 1
        return n
    }
}

/// 并发跑，结果按下标放回原位。shouldStop 为真后不再发新请求，没发的是 nil。
public func runConcurrently<T: Sendable, R: Sendable>(_ items: [T], limiter: ConcurrencyLimiter, shouldStop: @escaping @Sendable () -> Bool = { false },
                                                      onDone: @escaping @Sendable (Int) -> Void = { _ in },
                                                      body: @escaping @Sendable (T) async -> R) async -> [R?] {
    var out = [R?](repeating: nil, count: items.count)
    let counter = Counter()
    await withTaskGroup(of: (Int, R).self) { g in
        for (i, item) in items.enumerated() {
            await limiter.acquire()
            if shouldStop() {
                await limiter.release()
                break
            }
            g.addTask {
                let r = await body(item)
                await limiter.release()
                onDone(counter.next())      // 这里就报：要等全部排进去才收结果，界面进度和取消都会滞后
                return (i, r)
            }
        }
        for await (i, r) in g { out[i] = r }
    }
    return out
}

/// Retry-After：秒数或 HTTP 日期
func retryAfterSeconds(_ s: String?, now: Date = Date()) -> Double? {
    guard let s = s?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
    if let v = Double(s) { return max(0, v) }
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "GMT")
    f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
    return f.date(from: s).map { max(0, $0.timeIntervalSince(now)) }
}
#endif
