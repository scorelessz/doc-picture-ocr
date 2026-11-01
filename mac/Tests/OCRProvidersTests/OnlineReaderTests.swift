#if canImport(CryptoKit)
import Foundation
import XCTest
@testable import OCRProviders

final class MemoryLedger: UploadLedger, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var rows: [UploadRecord] = []
    var wireCountAtFirstWrite: (() -> Int)?
    private(set) var firstWriteSaw: Int?

    func write(_ r: UploadRecord) {
        lock.lock(); defer { lock.unlock() }
        if firstWriteSaw == nil { firstWriteSaw = wireCountAtFirstWrite?() }
        rows.append(r)
    }
}

private func ok(_ t: String) -> HTTPReply {
    HTTPReply(status: 200, body: try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": t]]]]))
}

final class OnlineReaderTests: XCTestCase {
    private var dir: URL!
    let host = "api.example.com"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("online-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func page(_ n: Int, bytes: Int = 10) throws -> OnlinePage {
        let f = dir.appendingPathComponent("p\(n).json")
        try Data(count: bytes).write(to: f)
        return OnlinePage(id: "p\(n)", sourceFile: "a.pdf", page: n, body: f, bytes: bytes)
    }

    private func make(_ pages: [OnlinePage], replies: [HTTPReply], ledger: UploadLedger) async throws -> (OnlineReader, MockWire) {
        let w = MockWire(replies), s = ProviderSelection(), g = UploadGate()
        s.select("p")
        let t = GuardedTransport(wire: w, network: NetworkSwitch(allowed: true), selection: s, gate: g)
        await g.request(onlineManifest(pages, providerID: "p", providerName: "P", host: host, model: "m"))
        let tk = try await g.confirm(checkbox: true, scope: .once)
        return (OnlineReader(transport: t, endpoint: try Endpoint("https://\(host)/v1"), providerID: "p", model: "m", key: nil,
                             ticket: tk, ledger: ledger, backoff: { _ in }), w)
    }

    func testReadsAndRecords() async throws {
        let p = try page(1), l = MemoryLedger()
        let (r, w) = try await make([p], replies: [ok("正文")], ledger: l)
        let t = try await r.read(p)
        XCTAssertEqual(t, "正文")
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(l.rows.map(\.status), ["pending", "ok"])
    }

    func testLedgerWrittenBeforeSend() async throws {    // 41
        let p = try page(1), l = MemoryLedger()
        let (r, w) = try await make([p], replies: [ok("x")], ledger: l)
        l.wireCountAtFirstWrite = { w.count }
        _ = try await r.read(p)
        XCTAssertEqual(l.firstWriteSaw, 0)
    }

    func testHardFailureStopsAtOneCall() async throws {  // 24
        let p = try page(1), l = MemoryLedger()
        let (r, w) = try await make([p], replies: [HTTPReply(status: 401)], ledger: l)
        do {
            _ = try await r.read(p)
            XCTFail()
        } catch { XCTAssertEqual(error as? OnlineError, .http(401)) }
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(Set(w.requests.compactMap { $0.url?.host }), [host])
    }

    func testRetriesAreBounded() async throws {          // 26
        let p = try page(1, bytes: 4), l = MemoryLedger()
        let (r, w) = try await make([p], replies: (0..<9).map { _ in HTTPReply(status: 503) }, ledger: l)
        do {
            _ = try await r.read(p)
            XCTFail()
        } catch { }
        XCTAssertLessThanOrEqual(w.count, OnlineReader.maxAttempts)
        XCTAssertEqual(Set(w.requests.compactMap { $0.url?.host }), [host], "失败绝不换家")
    }

    func testRetryRecoversAndRecordsEachAttempt() async throws {
        let p = try page(1), q = try page(2), l = MemoryLedger()
        let (r, w) = try await make([p, q], replies: [HTTPReply(status: 429), ok("x")], ledger: l)
        let t = try await r.read(p)
        XCTAssertEqual(t, "x")
        XCTAssertEqual(w.count, 2)
        XCTAssertEqual(l.rows.filter { $0.status == "pending" }.count, 2)
    }

    func testUnconfirmedPageIsRefused() async throws {
        let p = try page(1), other = try page(2), l = MemoryLedger()
        let (r, w) = try await make([p], replies: [], ledger: l)
        do {
            _ = try await r.read(other)
            XCTFail()
        } catch { XCTAssertEqual(error as? GateError, .itemNotInManifest) }
        XCTAssertEqual(w.count, 0)
        XCTAssertEqual(l.rows.last?.status.hasPrefix("failed:"), true)
    }

    func testFileLedgerLastStatusWins() throws {
        let u = dir.appendingPathComponent("u.jsonl"), l = try FileLedger(u)
        var r = UploadRecord(seq: 1, time: Date(), host: host, provider: "p", model: "m", ticket: "t", scope: "once", page: 3, item: "p3", bytes: 9, status: "pending")
        try l.write(r)
        r.status = "ok"
        try l.write(r)
        XCTAssertEqual(try FileLedger.rows(u).map(\.status), ["ok"])
    }

    func testBodyIsDeterministic() throws {
        XCTAssertEqual(try ChatBody.make(model: "m", png: Data([1, 2])), try ChatBody.make(model: "m", png: Data([1, 2])))
    }

    func testManifestSHAStable() throws {
        let p = try page(1)
        let a = onlineManifest([p], providerID: "p", providerName: "P", host: host, model: "m")
        let b = onlineManifest([p], providerID: "p", providerName: "P", host: host, model: "m")
        XCTAssertEqual(a.sha256, b.sha256)
        XCTAssertNotEqual(a.sha256, onlineManifest([p], providerID: "p", providerName: "P", host: host, model: "n").sha256)
    }
}
#endif

#if canImport(CryptoKit)
import OCRCore

final class ReconcileTests: XCTestCase {
    private func rec(_ seq: Int, _ page: Int, _ status: String = "ok") -> UploadRecord {
        UploadRecord(seq: seq, time: Date(), host: "h", provider: "p", model: "m", ticket: "t", scope: "once", page: page, item: "p\(page)", bytes: 9, status: status)
    }

    private func report(_ pages: [Int], called: Int? = nil) -> String {
        var s = "# 报告\n\n## 5　上传记录\n\n| 时间 | 域名 | 模型 | 页 | 字节 | 结果 |\n|---|---|---|---|---|---|\n"
        for p in pages { s += "| t | h | m | \(p) | 9 | ok |\n" }
        s += "\n## 6　VLM 第三票\n\n| 项 | 值 |\n|---|---|\n| 调用页数 | \(called ?? pages.count) |\n"
        return s
    }

    func testMatches() { XCTAssertEqual(reconcileUploads(report: report([1, 2]), rows: [rec(1, 1), rec(2, 2)]), []) }

    func testNoUploadsNoProblem() { XCTAssertEqual(reconcileUploads(report: "# 报告\n", rows: []), []) }

    func testReportMissingPage() { XCTAssertEqual(reconcileUploads(report: report([1], called: 2), rows: [rec(1, 1), rec(2, 2)]).count, 1) }

    func testLedgerMissingPage() { XCTAssertEqual(reconcileUploads(report: report([1, 2], called: 1), rows: [rec(1, 1)]).count, 1) }

    func testCalledPagesMismatch() {
        XCTAssertTrue(reconcileUploads(report: report([1], called: 3), rows: [rec(1, 1)]).contains { $0.contains("调用页数") })
    }

    func testPendingReported() {
        let r = "## 上传记录\n| t | h | m | 1 | 9 | pending |\n"
        XCTAssertTrue(reconcileUploads(report: r, rows: [rec(1, 1, "pending")]).contains { $0.contains("没有结果") })
    }
}

final class LogLeakTests: XCTestCase {
    /// 35、36：trace 全流程，开不开 --log-text，日志里都不能有 Key。没开时也不能有正文。
    func testNoKeyInLogs() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("leak-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let canary = "sk-canary-0123456789", secretText = "金丝雀正文"
        for withText in [false, true] {
            let log = dir.appendingPathComponent("\(withText).log")
            _ = try Log.shared.configure(["--log-level", "trace", "--log-file", log.path] + (withText ? ["--log-text"] : []), env: [:])
            let body = dir.appendingPathComponent("b.json")
            try Data(count: 10).write(to: body)
            let page = OnlinePage(id: "p1", sourceFile: "a.pdf", page: 1, body: body, bytes: 10)
            let w = MockWire([HTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": secretText]]]]))])
            let s = ProviderSelection(), g = UploadGate()
            s.select("p")
            let t = GuardedTransport(wire: w, network: NetworkSwitch(allowed: true), selection: s, gate: g)
            await g.request(onlineManifest([page], providerID: "p", providerName: "P", host: "api.example.com", model: "m"))
            let tk = try await g.confirm(checkbox: true, scope: .once)
            let r = OnlineReader(transport: t, endpoint: try Endpoint("https://api.example.com/v1"), providerID: "p", model: "m",
                                 key: SecretKey(canary), ticket: tk, ledger: try FileLedger(dir.appendingPathComponent("u.jsonl")), backoff: { _ in })
            _ = try await r.read(page)
            XCTAssertEqual(w.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer \(canary)")
            _ = try Log.shared.configure(["--log-level", "error"], env: [:])
            let text = try String(contentsOf: log, encoding: .utf8)
            XCTAssertTrue(text.contains("provider_request"), "日志要真的写了")
            XCTAssertFalse(text.contains(canary))
            XCTAssertFalse(text.contains(secretText))
            let ledger = try String(contentsOf: dir.appendingPathComponent("u.jsonl"), encoding: .utf8)
            XCTAssertFalse(ledger.contains(canary))
        }
    }
}
#endif
