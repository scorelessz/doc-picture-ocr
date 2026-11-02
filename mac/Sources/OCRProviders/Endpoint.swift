import Foundation

// 服务商地址。确认窗显示的域名就是这里的 host。

public enum EndpointError: Error, Equatable {
    case invalid, credentialsInURL, plainHTTP(String)
}

public struct Endpoint: Sendable, Hashable {
    public let baseURL: URL
    public let host: String
    public let isLoopback: Bool

    /// 非本机必须 https；URL 里带用户名密码时拒绝
    public init(_ raw: String) throws {
        guard let c = URLComponents(string: raw), let scheme = c.scheme?.lowercased(),
              ["http", "https"].contains(scheme), let h = c.host?.lowercased(), !h.isEmpty,
              let u = c.url else { throw EndpointError.invalid }
        if c.user != nil || c.password != nil { throw EndpointError.credentialsInURL }
        host = h
        isLoopback = Endpoint.loopback(h)
        if scheme == "http", !isLoopback { throw EndpointError.plainHTTP(h) }
        baseURL = u
    }

    /// 只认 localhost、127.0.0.0/8、::1。局域网地址和长得像的域名都算非本机。
    static func loopback(_ host: String) -> Bool {
        if host == "localhost" || host == "::1" || host == "[::1]" { return true }
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "127" else { return false }
        return parts.allSatisfy { p in
            !p.isEmpty && p.count <= 3 && p.allSatisfy(\.isNumber) && (Int(p) ?? 256) <= 255
        }
    }

    func url(path: String) throws -> URL {
        let base = baseURL.absoluteString.hasSuffix("/") ? String(baseURL.absoluteString.dropLast()) : baseURL.absoluteString
        let tail = path.hasPrefix("/") ? String(path.dropFirst()) : path
        guard let u = URL(string: tail.isEmpty ? base : base + "/" + tail), u.host?.lowercased() == host else {
            throw EndpointError.invalid
        }
        return u
    }
}
