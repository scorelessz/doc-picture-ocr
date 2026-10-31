import Foundation

// 诊断日志（docs/REFACTOR_PLAN.md §5.1）：只落本地，默认不写识别正文。
// 没开日志时所有调用都是空操作；开了才写，每行一条 JSON，或 --log-format text 给人读。

public enum LogLevel: Int, Comparable, Sendable {
    case off = 0, error, warn, info, debug, trace

    public init?(name: String) {
        switch name.lowercased() {
        case "off": self = .off
        case "error": self = .error
        case "warn", "warning": self = .warn
        case "info": self = .info
        case "debug": self = .debug
        case "trace": self = .trace
        default: return nil
        }
    }

    public var name: String { ["off", "error", "warn", "info", "debug", "trace"][rawValue] }
    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

public enum LogValue: Sendable {
    case s(String), i(Int), d(Double), b(Bool), a([LogValue]), o([String: LogValue]), null

    var json: Any {
        switch self {
        case .s(let v): return v
        case .i(let v): return v
        case .d(let v): return NSDecimalNumber(string: String(format: "%.6g", v))
        case .b(let v): return v
        case .a(let v): return v.map(\.json)
        case .o(let v): return v.mapValues(\.json)
        case .null: return NSNull()
        }
    }
}

public final class Log: @unchecked Sendable {
    public static let shared = Log()
    public init() {}

    public private(set) var level = LogLevel.off
    public private(set) var withText = false
    private var text = false
    private var handle: FileHandle?
    private let lock = NSLock()
    private let t0 = Date()

    public var enabled: Bool { level > .off }

    /// 从参数里摘掉日志选项，其余原样返回。DOCOCR_LOG 等价于 --log-level。
    public func configure(_ args: [String], env: [String: String]) throws -> [String] {
        var rest: [String] = [], file: String?, lvl = env["DOCOCR_LOG"].flatMap { LogLevel(name: $0) }
        var i = 0
        while i < args.count {
            let a = args[i]
            func value() throws -> String {
                guard i + 1 < args.count else { throw LogError.missingValue(a) }
                i += 1
                return args[i]
            }
            switch a {
            case "--log-level":
                let v = try value()
                guard let l = LogLevel(name: v) else { throw LogError.badLevel(v) }
                lvl = l
            case "--log-file": file = try value()
            case "--log-format":
                let v = try value()
                guard v == "json" || v == "text" else { throw LogError.badFormat(v) }
                text = v == "text"
            case "--log-text": withText = true
            default: rest.append(a)
            }
            i += 1
        }
        level = lvl ?? (file != nil ? .info : .off)
        if let file {
            let fm = FileManager.default
            try fm.createDirectory(at: URL(fileURLWithPath: file).deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: file) { fm.createFile(atPath: file, contents: nil) }
            handle = try FileHandle(forWritingTo: URL(fileURLWithPath: file))
            try handle?.seekToEnd()
        }
        return rest
    }

    public func write(_ l: LogLevel, _ event: String, _ fields: [String: LogValue] = [:]) {
        guard l <= level, l != .off else { return }
        var o = fields.mapValues(\.json)
        let elapsed = Date().timeIntervalSince(t0)
        o["t"] = NSDecimalNumber(string: String(format: "%.3f", elapsed))
        o["level"] = l.name
        o["event"] = event
        let line: String
        if text {
            let body = fields.keys.sorted().map { k -> String in
                let v = fields[k]!.json
                if let d = try? JSONSerialization.data(withJSONObject: v, options: [.fragmentsAllowed, .sortedKeys]) {
                    return "\(k)=\(String(decoding: d, as: UTF8.self))"
                }
                return "\(k)=?"
            }.joined(separator: " ")
            line = String(format: "%9.3f %-5@ %@ ", elapsed, l.name as NSString, event as NSString) + body
        } else {
            let d = (try? JSONSerialization.data(withJSONObject: o, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
            line = String(decoding: d, as: UTF8.self)
        }
        lock.lock()
        defer { lock.unlock() }
        let data = Data((line + "\n").utf8)
        if let handle { try? handle.write(contentsOf: data) } else { FileHandle.standardError.write(data) }
    }

    public func error(_ e: String, _ f: [String: LogValue] = [:]) { write(.error, e, f) }
    public func warn(_ e: String, _ f: [String: LogValue] = [:]) { write(.warn, e, f) }
    public func info(_ e: String, _ f: [String: LogValue] = [:]) { write(.info, e, f) }
    public func debug(_ e: String, _ f: [String: LogValue] = [:]) { write(.debug, e, f) }
    public func trace(_ e: String, _ f: [String: LogValue] = [:]) { write(.trace, e, f) }
}

public enum LogError: Error, CustomStringConvertible {
    case missingValue(String), badLevel(String), badFormat(String)

    public var description: String {
        switch self {
        case .missingValue(let a): return "\(a) 缺参数"
        case .badLevel(let v): return "--log-level 不认识: \(v)"
        case .badFormat(let v): return "--log-format 只能是 json 或 text: \(v)"
        }
    }
}
