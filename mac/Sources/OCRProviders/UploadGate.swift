#if canImport(CryptoKit)
import CryptoKit
import Foundation
import OCRCore

// 上传确认闸门。状态只在内存里；票据只有这里能发。状态机见 docs/P6_DESIGN.md 第 4 节。

public struct UploadItem: Sendable, Equatable, Codable {
    public let id: String, sourceFile: String, page: Int, bytes: Int

    public init(id: String, sourceFile: String, page: Int, bytes: Int) {
        self.id = id; self.sourceFile = sourceFile; self.page = page; self.bytes = bytes
    }
}

public enum Cost: Sendable, Equatable, Codable {
    case unknown
    case estimated(String)
}

public struct UploadManifest: Sendable, Equatable, Codable {
    public let providerID: String, providerName: String, host: String, model: String
    public let items: [UploadItem]
    public let estimatedRequests: Int
    public let estimatedCost: Cost
    /// 累计字节上限，重试也计入。默认等于清单总字节。
    public let byteLimit: Int

    public init(providerID: String, providerName: String, host: String, model: String, items: [UploadItem],
                estimatedRequests: Int, estimatedCost: Cost = .unknown, byteLimit: Int? = nil) {
        self.providerID = providerID; self.providerName = providerName; self.host = host; self.model = model
        self.items = items; self.estimatedRequests = estimatedRequests; self.estimatedCost = estimatedCost
        self.byteLimit = byteLimit ?? items.map(\.bytes).reduce(0, +)
    }

    public var totalBytes: Int { items.map(\.bytes).reduce(0, +) }

    /// --confirm-upload 比对的就是它
    public var sha256: String {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let d = (try? enc.encode(self)) ?? Data()
        return SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined()
    }
}

public enum Scope: Sendable, Equatable {
    case once, batch(UUID)
}

/// init 不公开：其他模块造不出票据。
public struct UploadTicket: Sendable, Equatable {
    public let id: UUID, host: String, scope: Scope

    fileprivate init(host: String, scope: Scope) {
        id = UUID(); self.host = host; self.scope = scope
    }
}

public enum GateState: Sendable, Equatable {
    case idle, awaitingConfirm(UploadManifest), confirmed(UploadTicket), running(UploadTicket)
    case declined, revoked(reason: String), finished
}

public enum GateError: Error, Equatable {
    case notAwaiting, checkboxNotTicked, digestMismatch
    case ticketInvalid, hostMismatch, itemNotInManifest, itemTooLarge, byteLimitExceeded
}

public actor UploadGate {
    public private(set) var state: GateState = .idle
    private var active: (ticket: UploadTicket, manifest: UploadManifest, sent: Int)?
    private var batch: (id: UUID, host: String, model: String)?

    public init() {}

    /// 新一次上传。批次内同 host 同模型直接发新票据，其余情况都要重新确认。
    @discardableResult
    public func request(_ m: UploadManifest) -> GateState {
        Log.shared.info("gate_request", ["host": .s(m.host), "items": .i(m.items.count), "bytes": .i(m.totalBytes),
                                         "requests": .i(m.estimatedRequests), "digest": .s(String(m.sha256.prefix(12)))])
        active = nil
        if let b = batch, b.host == m.host, b.model == m.model {
            let t = UploadTicket(host: m.host, scope: .batch(b.id))
            active = (t, m, 0)
            state = .confirmed(t)
            Log.shared.info("gate_decision", ["decision": .s("batch_reuse"), "scope": .s("batch"), "ticket": .s(short(t))])
            return state
        }
        batch = nil
        state = .awaitingConfirm(m)
        return state
    }

    /// 确认窗：复选框没勾就抛错，状态不变。
    public func confirm(checkbox: Bool, scope: Scope) throws -> UploadTicket {
        guard case .awaitingConfirm(let m) = state else { throw GateError.notAwaiting }
        guard checkbox else { throw GateError.checkboxNotTicked }
        return issue(m, scope: scope, decision: "confirmed")
    }

    /// 命令行：交互时用户手输的域名，或非交互的清单 sha256，只能确认这一份清单。
    public func confirm(manifestSHA256 sha: String) throws -> UploadTicket {
        guard case .awaitingConfirm(let m) = state else { throw GateError.notAwaiting }
        guard sha.lowercased() == m.sha256 else { throw GateError.digestMismatch }
        return issue(m, scope: .once, decision: "confirmed_digest")
    }

    private func issue(_ m: UploadManifest, scope: Scope, decision: String) -> UploadTicket {
        let t = UploadTicket(host: m.host, scope: scope)
        active = (t, m, 0)
        if case .batch(let id) = scope { batch = (id, m.host, m.model) }
        state = .confirmed(t)
        Log.shared.info("gate_decision", ["decision": .s(decision), "scope": .s(scopeName(scope)), "ticket": .s(short(t))])
        return t
    }

    public func decline() {
        Log.shared.info("gate_decision", ["decision": .s("declined")])
        active = nil
        batch = nil
        state = .declined
    }

    /// 单个任务结束。一次性票据作废；批次票据等 finishBatch。
    public func finish() {
        active = nil
        state = .finished
        if batch != nil { state = .idle }
    }

    public func finishBatch() {
        active = nil
        batch = nil
        state = .idle
    }

    /// 传输层发送前调用：校验并累计字节。超限时票据作废，回到重新询问。
    func authorize(_ t: UploadTicket, host: String, providerID: String, itemID: String, bytes: Int) throws {
        guard let a = active, a.ticket == t, a.manifest.providerID == providerID else {
            throw GateError.ticketInvalid
        }
        guard t.host == host else { throw GateError.hostMismatch }
        guard let item = a.manifest.items.first(where: { $0.id == itemID }) else { throw GateError.itemNotInManifest }
        guard bytes <= item.bytes else { throw GateError.itemTooLarge }
        if a.sent + bytes > a.manifest.byteLimit {
            revoke("超过确认的字节上限")
            throw GateError.byteLimitExceeded
        }
        active?.sent += bytes
        state = .running(t)
    }

    private func revoke(_ reason: String) {
        if let a = active { Log.shared.warn("gate_revoked", ["reason": .s(reason), "ticket": .s(short(a.ticket))]) }
        active = nil
        batch = nil
        state = .revoked(reason: reason)
    }

    private func short(_ t: UploadTicket) -> String { String(t.id.uuidString.prefix(8)) }

    private func scopeName(_ s: Scope) -> String {
        if case .batch = s { return "batch" }
        return "once"
    }
}
#endif
