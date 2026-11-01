#if canImport(CryptoKit)
import Foundation
import OCRCore
import XCTest
@testable import OCRProviders

/// 随机延迟的假线路：回答由请求体决定，记录同时在途的最大数。
final class JitterWire: WireClient, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0, active = 0, peakValue = 0
    var script: [HTTPReply] = []
    let answer: @Sendable (Data) -> String

    init(answer: @escaping @Sendable (Data) -> String) { self.answer = answer }

    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var peak: Int { lock.lock(); defer { lock.unlock() }; return peakValue }

    func perform(_ r: URLRequest) async throws -> HTTPReply {
        var scripted: HTTPReply?
        lock.lock()
        n += 1
        active += 1
        peakValue = max(peakValue, active)
        if !script.isEmpty { scripted = script.removeFirst() }
        lock.unlock()
        try await Task.sleep(nanoseconds: UInt64.random(in: 1_000_000...8_000_000))
        lock.lock()
        active -= 1
        lock.unlock()
        if let scripted { return scripted }
        let o: [String: Any] = ["choices": [["message": ["content": answer(r.httpBody ?? Data())]]]]
        return HTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: o))
    }

    func cancelAll() {}
}

final class ConcurrencyTests: XCTestCase {
    private var dir: URL!
    private let times = NSLock()
    private nonisolated(unsafe) var waits: [Double] = []

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("conc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func pages(_ n: Int) throws -> [OnlinePage] {
        try (1...n).map { i in
            let f = dir.appendingPathComponent("p\(i).json"), d = Data("正文\(i)".utf8)
            try d.write(to: f)
            return OnlinePage(id: "p\(i)", sourceFile: "a.pdf", page: i, body: f, bytes: d.count)
        }
    }

    private func reader(_ pages: [OnlinePage], wire: WireClient, jobs: Int, confirm: Bool = true) async throws -> (OnlineReader, UploadGate) {
        let s = ProviderSelection(), g = UploadGate()
        s.select("p")
        let t = GuardedTransport(wire: wire, network: NetworkSwitch(allowed: true), selection: s, gate: g)
        await g.request(onlineManifest(pages, providerID: "p", providerName: "P", host: "api.example.com", model: "m"))
        let tk = try await g.confirm(checkbox: true, scope: .once)
        if !confirm { await g.finish() }
        let me = self
        return (OnlineReader(transport: t, endpoint: try Endpoint("https://api.example.com/v1"), providerID: "p", model: "m", key: nil, ticket: tk,
                             ledger: MemoryLedger(), jobs: jobs, sleep: { s in
            me.times.lock(); me.waits.append(s); me.times.unlock()
        }), g)
    }

    private func all(_ ps: [OnlinePage], _ r: OnlineReader, stop: @escaping @Sendable () -> Bool = { false }, done: @escaping @Sendable (Int) -> Void = { _ in }) async -> [String?] {
        let rs: [String??] = await runConcurrently(ps, limiter: r.limiter, shouldStop: stop, onDone: done) { p -> String? in try? await r.read(p) }
        return rs.map { $0 ?? nil }
    }

    private func readAll(jobs: Int, n: Int = 40) async throws -> ([String?], JitterWire) {
        let ps = try pages(n), w = JitterWire { String(decoding: $0, as: UTF8.self) + "-结果" }
        let (r, _) = try await reader(ps, wire: w, jobs: jobs)
        let out = await all(ps, r)
        return (out, w)
    }

    func testConcurrency1And4Identical() async throws {            // (a)
        let (a, wa) = try await readAll(jobs: 1), (b, wb) = try await readAll(jobs: 4)
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.first, "正文1-结果")
        XCTAssertEqual(a.last, "正文40-结果")
        XCTAssertEqual(wa.peak, 1)
        XCTAssertGreaterThan(wb.peak, 1)
        XCTAssertLessThanOrEqual(wb.peak, 4)
    }

    func testAdjudicationConcurrency1And4Identical() async throws {
        func line(_ i: Int) -> String {
            "{\"x\":0,\"y\":\(i * 10),\"w\":10,\"h\":8,\"text\":\"甲\(i)\",\"conf\":1,\"src\":\"both\",\"alt\":\"乙\(i)\",\"flag\":\"divergent\"}"
        }
        let stats = "{\"pages\":1,\"lines\":0,\"both\":0,\"divergent\":0,\"only_vision\":0,\"only_rapidocr\":0,\"low_conf\":0,\"glossary_hits\":0,\"dropped_empty\":0,\"dropped_contained\":0}"
        let j = "{\"source\":\"a\",\"engines\":[\"v\"],\"stats\":\(stats),\"dpi\":300,\"pages\":[{\"page\":1,\"width\":100,\"height\":100,\"pdf_width\":50,\"pdf_height\":50,\"zoom\":2,\"rotation\":0,\"native_text\":false,\"lines\":[\((0..<20).map(line).joined(separator: ","))]}]}"
        let doc = try JSONDecoder().decode(FusedDoc.self, from: Data(j.utf8))
        let qs = adjudicationQuestions(doc, pages: nil, mode: .text) { _, _ in nil }
        let ps = try qs.map { q -> OnlinePage in
            let b = try AdjudicationBody.make(model: "m", q), f = dir.appendingPathComponent(q.id)
            try b.write(to: f)
            return OnlinePage(id: q.id, sourceFile: "a", page: 1, body: f, bytes: b.count)
        }
        func run(_ k: Int) async throws -> FusedDoc {
            let w = JitterWire { _ in "{\"choice\": 1}" }
            let (r, _) = try await reader(ps, wire: w, jobs: k)
            return await runAdjudication(doc, questions: qs, pages: ps, mode: .text, reader: r, providerID: "p", model: "m").doc
        }
        let a = try await run(1), b = try await run(4)
        XCTAssertEqual(a, b)
    }

    func testUnconfirmedZeroRequests() async throws {               // (b)
        let ps = try pages(6), w = JitterWire { _ in "x" }
        let (r, _) = try await reader(ps, wire: w, jobs: 4, confirm: false)
        let out = await all(ps, r)
        XCTAssertEqual(w.count, 0)
        XCTAssertTrue(out.allSatisfy { $0 == nil })
    }

    func test429BacksOffAndLowersConcurrency() async throws {       // (c)
        let ps = try pages(8), w = JitterWire { _ in "ok" }
        w.script = (0..<4).map { _ in HTTPReply(status: 429) }
        let (r, _) = try await reader(ps, wire: w, jobs: 4)
        let out = await all(ps, r)
        XCTAssertTrue(out.allSatisfy { $0 == "ok" }, "429 之后重试成功")
        XCTAssertEqual(w.count, 12)
        XCTAssertFalse(waits.isEmpty, "要退避")
        let k = await r.limiter.limit
        XCTAssertLessThan(k, 4, "连续限流要降并发")
    }

    func testRetryAfterIsHonoured() async throws {
        let ps = try pages(1), w = JitterWire { _ in "ok" }
        w.script = [HTTPReply(status: 429, retryAfter: "7")]
        let (r, _) = try await reader(ps, wire: w, jobs: 1)
        _ = try await r.read(ps[0])
        XCTAssertEqual(waits, [7])
    }

    func testBackoffIsExponentialWithoutRetryAfter() async throws {
        let ps = try pages(1), w = JitterWire { _ in "ok" }
        w.script = (0..<3).map { _ in HTTPReply(status: 429) }
        let (r, _) = try await reader(ps, wire: w, jobs: 1)
        _ = try await r.read(ps[0])
        XCTAssertEqual(waits, [2, 4, 8])
    }

    func testRetryAfterParsing() throws {
        XCTAssertEqual(retryAfterSeconds("12"), 12)
        XCTAssertNil(retryAfterSeconds(nil))
        XCTAssertNil(retryAfterSeconds("soon"))
        let now = Date(timeIntervalSince1970: 1_445_412_480)
        XCTAssertEqual(try XCTUnwrap(retryAfterSeconds("Wed, 21 Oct 2015 07:28:30 GMT", now: now)), 30, accuracy: 1)
    }

    func testPersistent429GivesUpWithoutSwitching() async throws {
        let ps = try pages(1), w = JitterWire { _ in "ok" }
        w.script = (0..<20).map { _ in HTTPReply(status: 429) }
        let (r, _) = try await reader(ps, wire: w, jobs: 2)
        do {
            _ = try await r.read(ps[0])
            XCTFail()
        } catch { XCTAssertEqual(error as? OnlineError, .http(429)) }
        XCTAssertEqual(w.count, OnlineReader.maxRateLimitAttempts)
    }

    func testCancelStopsUnsentRequests() async throws {
        let ps = try pages(30), w = JitterWire { _ in "ok" }
        let (r, _) = try await reader(ps, wire: w, jobs: 2)
        let stop = Flag()
        let out = await all(ps, r, stop: { stop.on }, done: { if $0 >= 4 { stop.on = true } })
        XCTAssertLessThan(w.count, 30)
        XCTAssertTrue(out.contains { $0 == nil })
    }

    func testEveryAttemptIsRecordedBeforeSending() async throws {
        let ps = try pages(5), w = JitterWire { _ in "ok" }, l = MemoryLedger()
        let s = ProviderSelection(), g = UploadGate()
        s.select("p")
        let t = GuardedTransport(wire: w, network: NetworkSwitch(allowed: true), selection: s, gate: g)
        await g.request(onlineManifest(ps, providerID: "p", providerName: "P", host: "api.example.com", model: "m"))
        let tk = try await g.confirm(checkbox: true, scope: .once)
        let r = OnlineReader(transport: t, endpoint: try Endpoint("https://api.example.com/v1"), providerID: "p", model: "m", key: nil, ticket: tk, ledger: l, jobs: 3, sleep: { _ in })
        _ = await all(ps, r)
        XCTAssertEqual(l.rows.filter { $0.status == "pending" }.count, 5)
        XCTAssertEqual(Set(l.rows.map(\.seq)).count, 5, "并发时序号不能撞")
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var on: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
#endif
