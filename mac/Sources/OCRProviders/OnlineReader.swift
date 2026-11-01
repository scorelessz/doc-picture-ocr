#if canImport(CryptoKit)
import Foundation
import OCRCore

// 在线读字。失败只影响这一页：保留本地结果，绝不换家。请求体在确认前就定好，确认的就是这些字节。

public struct OnlinePage: Sendable {
    public let id: String, sourceFile: String, page: Int, body: URL, bytes: Int

    public init(id: String, sourceFile: String, page: Int, body: URL, bytes: Int) {
        self.id = id; self.sourceFile = sourceFile; self.page = page; self.body = body; self.bytes = bytes
    }
}

public enum ChatBody {
    public static let transcribePrompt = "逐字转写图中的全部文字，保持原有换行，不要翻译、不要改动、不要添加任何说明。"

    public static func make(model: String, png: Data, prompt: String = transcribePrompt) throws -> Data {
        let content: [[String: Any]] = [["type": "image_url", "image_url": ["url": "data:image/png;base64,\(png.base64EncodedString())"]],
                                        ["type": "text", "text": prompt]]
        return try JSONSerialization.data(withJSONObject: ["model": model, "temperature": 0, "max_tokens": 4096,
                                                           "messages": [["role": "user", "content": content]]], options: [.sortedKeys])
    }

    static func text(_ d: Data) -> String? {
        guard let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let c = o["choices"] as? [[String: Any]],
              let m = c.first?["message"] as? [String: Any] else { return nil }
        return m["content"] as? String
    }
}

/// 清单：列的是所有可能上传的页，是上界。字节上限给重试留一半余量。
public func onlineManifest(_ pages: [OnlinePage], providerID: String, providerName: String, host: String, model: String) -> UploadManifest {
    let items = pages.map { UploadItem(id: $0.id, sourceFile: $0.sourceFile, page: $0.page, bytes: $0.bytes) }
    let total = items.map(\.bytes).reduce(0, +)
    return UploadManifest(providerID: providerID, providerName: providerName, host: host, model: model, items: items,
                          estimatedRequests: items.count, byteLimit: total + total / 2)
}

public struct UploadRecord: Sendable, Codable, Equatable {
    public let seq: Int, time: Date, host: String, provider: String, model: String, ticket: String, scope: String
    public let page: Int, item: String, bytes: Int
    public var status: String
}

public protocol UploadLedger: Sendable {
    func write(_ r: UploadRecord) throws
}

/// 每次状态变化追加一行，同一 seq 以最后一行为准。
public final class FileLedger: UploadLedger, @unchecked Sendable {
    private let url: URL, lock = NSLock()

    public init(_ url: URL) throws {
        self.url = url
        if !FileManager.default.fileExists(atPath: url.path) { try Data().write(to: url) }
    }

    public func write(_ r: UploadRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys]
        let h = try FileHandle(forWritingTo: url)
        defer { try? h.close() }
        try h.seekToEnd()
        try h.write(contentsOf: try enc.encode(r) + Data("\n".utf8))
        try h.synchronize()
    }

    public static func rows(_ url: URL) throws -> [UploadRecord] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        var last: [Int: UploadRecord] = [:]
        for l in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let r = try dec.decode(UploadRecord.self, from: Data(l.utf8))
            last[r.seq] = r
        }
        return last.values.sorted { $0.seq < $1.seq }
    }
}

public enum OnlineError: Error, Equatable {
    case http(Int), emptyReply
}

/// 一家服务商、一张票据。没有备选服务商这个概念。
public final class OnlineReader: @unchecked Sendable {
    static let maxAttempts = 3
    let transport: HTTPTransport, endpoint: Endpoint, providerID: String, model: String, key: SecretKey?
    let ticket: UploadTicket, ledger: UploadLedger, backoff: @Sendable (Int) async -> Void
    private let lock = NSLock()
    private var seq = 0

    public init(transport: HTTPTransport, endpoint: Endpoint, providerID: String, model: String, key: SecretKey?, ticket: UploadTicket,
                ledger: UploadLedger, backoff: @escaping @Sendable (Int) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0) * 2_000_000_000) }) {
        self.transport = transport; self.endpoint = endpoint; self.providerID = providerID; self.model = model
        self.key = key; self.ticket = ticket; self.ledger = ledger; self.backoff = backoff
    }

    private func nextSeq() -> Int {
        lock.lock()
        defer { lock.unlock() }
        seq += 1
        return seq
    }

    private func retryable(_ status: Int) -> Bool { status == 429 || (500..<600).contains(status) }

    public func read(_ p: OnlinePage) async throws -> String {
        let body = try Data(contentsOf: p.body)
        var lastError: Error = OnlineError.emptyReply
        var scope = "once"
        if case .batch = ticket.scope { scope = "batch" }
        for attempt in 1...Self.maxAttempts {
            var rec = UploadRecord(seq: nextSeq(), time: Date(), host: endpoint.host, provider: providerID, model: model,
                                   ticket: String(ticket.id.uuidString.prefix(8)), scope: scope, page: p.page, item: p.id,
                                   bytes: body.count, status: "pending")
            try ledger.write(rec)       // 先写后发，崩溃也不漏记
            do {
                let r = try await transport.send(OutboundRequest(endpoint: endpoint, providerID: providerID, path: "chat/completions",
                                                                 payload: .userData(body: body, ticket: ticket, itemID: p.id), key: key))
                if r.status == 200, let t = ChatBody.text(r.body), !t.isEmpty {
                    rec.status = "ok"
                    try ledger.write(rec)
                    return t
                }
                lastError = r.status == 200 ? OnlineError.emptyReply : OnlineError.http(r.status)
                rec.status = "failed:http_\(r.status)"
                try ledger.write(rec)
                guard retryable(r.status), attempt < Self.maxAttempts else { throw lastError }
            } catch let e as URLError {
                lastError = e
                rec.status = "failed:url_\(e.errorCode)"
                try ledger.write(rec)
                guard attempt < Self.maxAttempts else { throw e }
            } catch let e as OnlineError {
                throw e
            } catch {
                rec.status = "failed:\(error)"      // 策略拒绝：不重试
                try ledger.write(rec)
                throw error
            }
            await backoff(attempt)
        }
        throw lastError
    }
}
#endif
