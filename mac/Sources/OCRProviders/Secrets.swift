import Foundation

// Key 的包装类型：打印和日志里只有 <redacted>，不实现 Encodable。

public struct SecretKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let value: String

    public init(_ value: String) { self.value = value }

    public var description: String { "<redacted>" }
    public var debugDescription: String { "<redacted>" }
    public var customMirror: Mirror { Mirror(self, children: []) }
}
