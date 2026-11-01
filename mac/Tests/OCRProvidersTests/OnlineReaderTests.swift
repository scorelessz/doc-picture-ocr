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
