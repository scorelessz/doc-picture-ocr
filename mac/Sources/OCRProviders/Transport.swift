#if canImport(CryptoKit)
import Foundation
import OCRCore

// 工程里唯一发 HTTP 的地方。GuardedTransport 做全部检查，WireClient 才真正发包。

public struct HTTPReply: Sendable {
    public let status: Int, body: Data, location: String?

    public init(status: Int, body: Data = Data(), location: String? = nil) {
        self.status = status; self.body = body; self.location = location
    }
}

/// 合成图：init 不公开，页面图变不成这个类型。
public struct SyntheticImage: Sendable {
    public let png: Data, code: String

    init(png: Data, code: String) { self.png = png; self.code = code }
}

public struct ProbeRequest: Sendable {
    public let model: String, prompt: String, image: SyntheticImage?, wantJSON: Bool

    public init(model: String, prompt: String, image: SyntheticImage?, wantJSON: Bool = false) {
        self.model = model; self.prompt = prompt; self.image = image; self.wantJSON = wantJSON
    }

    /// 请求体由这里生成。max_tokens 要留够，带思考的模型会先用掉一部分，否则正文是空的。，调用方没有地方塞入别的内容
    var body: Data {
        var content: [[String: Any]] = [["type": "text", "text": prompt]]
        if let image {
            content.insert(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(image.png.base64EncodedString())"]], at: 0)
        }
        var o: [String: Any] = ["model": model, "temperature": 0, "max_tokens": 512, "messages": [["role": "user", "content": content]]]
        if wantJSON { o["response_format"] = ["type": "json_object"] }
        return (try? JSONSerialization.data(withJSONObject: o)) ?? Data()
    }
}

public enum Payload: Sendable {
    case userData(body: Data, ticket: UploadTicket, itemID: String)   // 用户内容
    case probe(ProbeRequest)                                          // 探测，图只能是合成图
    case metadata                                                     // GET /models
    case loopback(body: Data)                                         // 只发本机
}

public struct OutboundRequest: Sendable {
    public let endpoint: Endpoint, providerID: String, path: String, payload: Payload, key: SecretKey?

    public init(endpoint: Endpoint, providerID: String, path: String, payload: Payload, key: SecretKey? = nil) {
        self.endpoint = endpoint; self.providerID = providerID; self.path = path; self.payload = payload; self.key = key
    }
}

public enum Refusal: String, Sendable {
    case networkOff = "network_off", providerNotSelected = "provider_not_selected"
    case loopbackPayloadToRemote = "loopback_payload_to_remote", userDataToLoopback = "user_data_to_loopback"
    case redirectBlocked = "redirect_blocked", tooManyRedirects = "too_many_redirects"
}

public enum TransportError: Error, Equatable {
    case refused(Refusal)
    case badResponse
}

public protocol HTTPTransport: Sendable {
    func send(_ r: OutboundRequest) async throws -> HTTPReply
}

/// 真正出网的一层。不跟随重定向：3xx 原样交回，由 GuardedTransport 重新检查。
public protocol WireClient: Sendable {
    func perform(_ r: URLRequest) async throws -> HTTPReply
    func cancelAll()
}

public struct GuardedTransport: HTTPTransport {
    static let maxRedirects = 3
    let wire: WireClient, network: NetworkSwitch, selection: ProviderSelection, gate: UploadGate

    public init(wire: WireClient, network: NetworkSwitch, selection: ProviderSelection, gate: UploadGate) {
        self.wire = wire; self.network = network; self.selection = selection; self.gate = gate
        network.onDisable { [wire] in wire.cancelAll() }
    }

    private func refuse(_ why: Refusal, _ r: OutboundRequest) -> TransportError {
        Log.shared.warn("provider_refused", ["reason": .s(why.rawValue), "host": .s(r.endpoint.host), "provider": .s(r.providerID)])
        return .refused(why)
    }

    private func checkPolicy(_ r: OutboundRequest) throws {
        if r.endpoint.isLoopback {
            if case .userData = r.payload { throw refuse(.userDataToLoopback, r) }
            return
        }
        if case .loopback = r.payload { throw refuse(.loopbackPayloadToRemote, r) }
        guard network.allowed else { throw refuse(.networkOff, r) }
        guard selection.isSelected(r.providerID) else { throw refuse(.providerNotSelected, r) }
    }

    public func send(_ r: OutboundRequest) async throws -> HTTPReply {
        var url = try r.endpoint.url(path: r.path)
        for attempt in 0...Self.maxRedirects {
            try checkPolicy(r)
            var q = URLRequest(url: url)
            switch r.payload {
            case .metadata:
                q.httpMethod = "GET"
            case let .userData(body, ticket, itemID):
                do {
                    try await gate.authorize(ticket, host: r.endpoint.host, providerID: r.providerID, itemID: itemID, bytes: body.count)
                } catch {
                    Log.shared.warn("provider_refused", ["reason": .s("\(error)"), "host": .s(r.endpoint.host), "item": .s(itemID)])
                    throw error
                }
                q.httpMethod = "POST"
                q.httpBody = body
            case .probe(let p):
                q.httpMethod = "POST"
                q.httpBody = p.body
            case .loopback(let body):
                q.httpMethod = "POST"
                q.httpBody = body
            }
            try checkPolicy(r)          // 闸门检查是 await，这期间总开关可能已经关了
            if q.httpBody != nil { q.setValue("application/json", forHTTPHeaderField: "Content-Type") }
            if let k = r.key { q.setValue("Bearer \(k.value)", forHTTPHeaderField: "Authorization") }
            Log.shared.debug("provider_request", ["host": .s(r.endpoint.host), "provider": .s(r.providerID),
                                                  "bytes": .i(q.httpBody?.count ?? 0), "attempt": .i(attempt)])
            let t0 = Date()
            let reply = try await wire.perform(q)
            Log.shared.debug("provider_response", ["host": .s(r.endpoint.host), "status": .i(reply.status), "bytes": .i(reply.body.count),
                                                   "seconds": .d((Date().timeIntervalSince(t0) * 1000).rounded() / 1000)])
            guard [301, 302, 303, 307, 308].contains(reply.status), let loc = reply.location else { return reply }
            guard let next = URL(string: loc, relativeTo: url)?.absoluteURL, next.host?.lowercased() == r.endpoint.host,
                  next.scheme?.lowercased() == url.scheme?.lowercased() else {
                Log.shared.warn("redirect_blocked", ["from": .s(r.endpoint.host), "to": .s(URL(string: loc)?.host ?? "?")])
                throw refuse(.redirectBlocked, r)
            }
            url = next
        }
        throw refuse(.tooManyRedirects, r)
    }
}

/// 真实网络。ephemeral，不缓存、不存 cookie，图片不落磁盘；重定向一律不跟随。
public final class URLSessionWire: NSObject, WireClient, URLSessionTaskDelegate, @unchecked Sendable {
    static var configuration: URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.timeoutIntervalForRequest = 300
        return c
    }

    private lazy var session = URLSession(configuration: Self.configuration, delegate: self, delegateQueue: nil)

    public func perform(_ r: URLRequest) async throws -> HTTPReply {
        let (d, resp) = try await session.data(for: r)
        guard let h = resp as? HTTPURLResponse else { throw TransportError.badResponse }
        return HTTPReply(status: h.statusCode, body: d, location: h.value(forHTTPHeaderField: "Location"))
    }

    public func cancelAll() {
        session.getAllTasks { $0.forEach { $0.cancel() } }
    }

    public func urlSession(_ s: URLSession, task: URLSessionTask, willPerformHTTPRedirection r: HTTPURLResponse,
                           newRequest q: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
#endif
