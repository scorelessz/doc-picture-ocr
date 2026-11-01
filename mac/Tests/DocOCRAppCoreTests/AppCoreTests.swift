import DocOCRAppCore
import Foundation
import OCREngines
import OCRProviders
import XCTest

final class Mem: KVStore {
    var d: [String: String] = [:]
    func string(_ k: String) -> String? { d[k] }
    func set(_ v: String?, _ k: String) { d[k] = v }
}

/// 计数的假线路：count 就是真正出网的次数
final class CountingWire: WireClient, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0, hosts = Set<String>()
    let reply: HTTPReply

    init(status: Int = 200) {
        reply = HTTPReply(status: status, body: try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "读到的字"]]]]))
    }

    var count: Int { lock.lock(); defer { lock.unlock() }; return n }
    var seenHosts: Set<String> { lock.lock(); defer { lock.unlock() }; return hosts }

    func perform(_ r: URLRequest) async throws -> HTTPReply {
        lock.lock(); defer { lock.unlock() }
        n += 1
        hosts.insert(r.url?.host ?? "?")
        return reply
    }

    func cancelAll() {}
}

/// 不跑真 OCR。有票据时真的走 OnlinePlan.attach 和传输层，走到假线路上计数。
final class FakeBackend: BookBackend, @unchecked Sendable {
    private let lock = NSLock()
    private var ran: [URL] = []
    var error: Error?
    var runs: Int { lock.lock(); defer { lock.unlock() }; return ran.count }
    let dir: URL

    init(dir: URL) { self.dir = dir }

    func prepare(preset: ProviderPreset, model: String, pdf: URL, forceOCR: Bool, workdir: URL) async throws -> OnlinePlan {
        let bodies = dir.appendingPathComponent(pdf.lastPathComponent + ".upload", isDirectory: true)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        let f = bodies.appendingPathComponent("p1.json")
        try Data(count: 10).write(to: f)
        let pages = [OnlinePage(id: "p1", sourceFile: pdf.lastPathComponent, page: 1, body: f, bytes: 10)]
        let ep = try Endpoint(preset.baseURL)
        return OnlinePlan(preset: preset, endpoint: ep, model: model, pages: pages,
                          manifest: onlineManifest(pages, providerID: preset.id, providerName: preset.name, host: ep.host, model: model), bodies: bodies)
    }

    func run(_ opts: BookOptions, plan: OnlinePlan?, ticket: UploadTicket?, app: BackendContext) async throws -> BookResult {
        lock.lock(); ran.append(opts.pdf); lock.unlock()
        if opts.isCancelled?() == true { throw BookError.cancelled }
        if let error { throw error }
        var o = opts
        if let plan, let ticket {
            try plan.attach(to: &o, transport: app.transport, key: app.key, ticket: ticket)
            let f = o.vlmOnline
            try await Task.detached { [f] in
                do { _ = try f?(1) } catch OnlineError.http { }     // 真流程里这是一页降级，不是任务失败
            }.value
        }
        var r = BookResult()
        r.pages = 1
        r.outputs = [opts.outdir.appendingPathComponent("a.report.md").path]
        return r
    }
}

@MainActor
final class AppCoreTests: XCTestCase {
    private var dir: URL!
    let qwen = ProviderPresets.find("dashscope")!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("app-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    private func models() throws -> URL {
        let m = dir.appendingPathComponent("models", isDirectory: true)
        try FileManager.default.createDirectory(at: m, withIntermediateDirectories: true)
        try Data().write(to: m.appendingPathComponent("keys.txt"))
        return m
    }

    private struct Rig {
        let app: AppModel, q: QueueModel, wire: CountingWire, backend: FakeBackend, secrets: MemorySecretStore
    }

    private func rig(network: Bool = true, online: Bool = true, status: Int = 200, store: Mem = Mem()) throws -> Rig {
        let w = CountingWire(status: status), s = MemorySecretStore(), a = AppModel(store: store, wire: w, secrets: s)
        s.save("sk-test", for: "dashscope")
        if network { a.allowNetwork() } else { a.chooseLocalOnly() }
        let b = FakeBackend(dir: dir)
        let q = QueueModel(app: a, backend: b, modelsDir: try models(), history: History(url: dir.appendingPathComponent("h.json")), outdir: dir)
        if online {
            a.setSelected(qwen, true)
            q.onlineProviderID = "dashscope"
            q.onlineModel = "m"
        }
        return Rig(app: a, q: q, wire: w, backend: b, secrets: s)
    }

    private func until(_ c: @MainActor () -> Bool) async {
        for _ in 0..<500 {
            if c() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("等待超时")
    }

    private func pdf(_ n: String) -> URL { dir.appendingPathComponent(n + ".pdf") }

    // MARK: 总开关

    func testDefaultIsLocalOnly() {
        let a = AppModel(store: Mem(), wire: CountingWire(), secrets: MemorySecretStore())
        XCTAssertFalse(a.onboardingDone)
        XCTAssertFalse(a.networkControlsEnabled)
        XCTAssertNotNil(a.networkDisabledReason)
    }

    func testOffDisablesAllProviderControls() {
        let a = AppModel(store: Mem(), wire: CountingWire(), secrets: MemorySecretStore())
        for p in ProviderPresets.all {
            XCTAssertFalse(a.canUse(p))
            XCTAssertNotNil(a.unavailableReason(p))
            a.setSelected(p, true)
            XCTAssertFalse(a.selected.contains(p.id))
        }
    }

    func testAllowingNetworkEnablesNoProvider() {
        let a = AppModel(store: Mem(), wire: CountingWire(), secrets: MemorySecretStore())
        a.allowNetwork()
        XCTAssertTrue(a.selected.isEmpty)
        for p in ProviderPresets.all { XCTAssertFalse(a.isUsable(p.id)) }
    }

    func testTestConnectionDisabledWhenOff() {
        let s = MemorySecretStore(), a = AppModel(store: Mem(), wire: CountingWire(), secrets: s)
        a.allowNetwork()
        a.setSelected(qwen, true)
        s.save("k", for: qwen.id)
        let p = ProviderSettings(app: a)
        p.models[qwen.id] = "m"
        XCTAssertTrue(p.canTest(qwen))
        a.turnOffNetwork()
        XCTAssertFalse(p.canTest(qwen))
    }

    func testTestConnectionNeedsSelection() {
        let s = MemorySecretStore(), w = CountingWire(), a = AppModel(store: Mem(), wire: w, secrets: s)
        a.allowNetwork()
        s.save("k", for: qwen.id)
        let p = ProviderSettings(app: a)
        p.models[qwen.id] = "m"
        XCTAssertFalse(p.canTest(qwen), "有 Key 但没选中")
        p.test(qwen)
        XCTAssertEqual(w.count, 0)
    }

    func testOffPersistsAndOnlineStopsWorking() throws {
        let st = Mem(), r = try rig(store: st)
        XCTAssertTrue(r.q.onlineEnabled)
        r.app.turnOffNetwork()
        XCTAssertFalse(r.q.onlineEnabled)
        XCTAssertEqual(r.q.blockReason, AppModel.offReason)
        let again = AppModel(store: st, wire: CountingWire(), secrets: MemorySecretStore())
        XCTAssertFalse(again.networkAllowed)
        XCTAssertFalse(again.network.allowed)
    }

    func testAnthropicIsOnlyAListEntry() {
        let a = AppModel(store: Mem(), wire: CountingWire(), secrets: MemorySecretStore())
        a.allowNetwork()
        let p = ProviderPresets.find("anthropic")!
        XCTAssertFalse(a.canUse(p))
        a.setSelected(p, true)
        XCTAssertFalse(a.selected.contains("anthropic"))
    }

    // MARK: 未确认零请求

    func testLocalRunMakesNoRequests() async throws {
        let r = try rig(online: false)
        r.q.add([pdf("a")])
        r.q.start()
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.backend.runs, 1)
        XCTAssertEqual(r.wire.count, 0)
    }

    func testAwaitingConfirmZeroRequests() async throws {
        let r = try rig()
        r.q.add([pdf("a")])
        r.q.start()
        await until { r.q.confirm != nil }
        XCTAssertEqual(r.wire.count, 0)
        XCTAssertEqual(r.backend.runs, 0, "确认前不开始任何处理")
        XCTAssertEqual(r.q.jobs[0].status, .awaitingConfirm)
        r.q.confirmUpload(checkbox: false, forBatch: false)      // 没勾选
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertNotNil(r.q.confirm)
        XCTAssertEqual(r.wire.count, 0)
        r.q.declineUpload()
        await r.q.waitUntilIdle()
    }

    func testDeclineStartsNothing() async throws {
        let r = try rig()
        r.q.add([pdf("a"), pdf("b")])
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.declineUpload()
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.q.jobs[0].status, .declined)
        XCTAssertEqual(r.q.jobs[1].status, .queued, "不降级成本地，也不继续下一份")
        XCTAssertEqual(r.backend.runs, 0)
        XCTAssertEqual(r.wire.count, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("a.pdf.upload").path), "页面图片不留")
    }

    func testCancelWhileAwaiting() async throws {
        let r = try rig()
        r.q.add([pdf("a")])
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.cancel()
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.q.jobs[0].status, .cancelled)
        XCTAssertEqual(r.wire.count, 0)
    }

    func testConfirmedSends() async throws {
        let r = try rig()
        r.q.add([pdf("a")])
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.confirmUpload(checkbox: true, forBatch: false)
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.wire.count, 1)
        XCTAssertEqual(r.wire.seenHosts, ["dashscope.aliyuncs.com"])
        XCTAssertEqual(r.q.jobs[0].status, .done)
    }

    func testOnceAsksAgainForNextFile() async throws {
        let r = try rig()
        r.q.add([pdf("a"), pdf("b")])
        r.q.start()
        await until { r.q.confirm?.fileName == "a.pdf" }
        r.q.confirmUpload(checkbox: true, forBatch: false)
        await until { r.q.confirm?.fileName == "b.pdf" }
        XCTAssertEqual(r.wire.count, 1)
        r.q.declineUpload()
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.wire.count, 1)
    }

    func testBatchScopeDoesNotAskAgain() async throws {
        let r = try rig()
        r.q.add([pdf("a"), pdf("b")])
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.confirmUpload(checkbox: true, forBatch: true)
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.wire.count, 2)
    }

    func testBatchConfirmDoesNotOutliveBatch() async throws {
        let r = try rig()
        r.q.add([pdf("a")])
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.confirmUpload(checkbox: true, forBatch: true)
        await r.q.waitUntilIdle()
        r.q.add([pdf("b")])
        r.q.start()
        await until { r.q.confirm != nil }
        XCTAssertEqual(r.wire.count, 1)
        r.q.declineUpload()
        await r.q.waitUntilIdle()
    }

    func testMissingKeyFailsWithoutRequest() async throws {
        let r = try rig()
        r.secrets.delete("dashscope")
        r.q.add([pdf("a")])
        r.q.start()
        await r.q.waitUntilIdle()
        guard case .failed = r.q.jobs[0].status else { return XCTFail() }
        XCTAssertEqual(r.wire.count, 0)
    }

    func testProviderFailureNeverSwitches() async throws {
        let r = try rig(status: 401)
        r.app.setSelected(ProviderPresets.find("deepseek")!, true)     // 另一家也选中、也有 Key
        r.secrets.save("k", for: "deepseek")
        r.q.add([pdf("a")])
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.confirmUpload(checkbox: true, forBatch: false)
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.wire.seenHosts.count, 1)
        XCTAssertEqual(r.wire.count, 1)
    }

    // MARK: 队列

    func testNeedsAtLeastOneOutput() throws {
        let r = try rig(online: false)
        r.q.add([pdf("a")])
        XCTAssertTrue(r.q.canStart)
        r.q.makeMarkdown = false
        r.q.makePDF = false
        XCTAssertFalse(r.q.canStart)
        XCTAssertNotNil(r.q.blockReason)
    }

    func testHighPrecisionNeedsModel() throws {
        let r = try rig(online: false)
        r.q.add([pdf("a")])
        r.q.highPrecision = true
        XCTAssertTrue(r.q.needsVLModel)
        XCTAssertFalse(r.q.canStart)
    }

    func testOnlyPDFsAreAddedOnce() throws {
        let r = try rig(online: false)
        r.q.add([pdf("a"), pdf("a"), dir.appendingPathComponent("x.txt")])
        r.q.add([pdf("a")])
        XCTAssertEqual(r.q.jobs.count, 1)
    }

    func testFailureContinuesToNextFile() async throws {
        let r = try rig(online: false)
        r.backend.error = BookError.failed("坏文件")
        r.q.add([pdf("a"), pdf("b")])
        r.q.start()
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.backend.runs, 2)
    }

    func testHistoryMarksInterruptedAndFindsOutputs() throws {
        let h = dir.appendingPathComponent("h.json"), a = History(url: h)
        try Data().write(to: dir.appendingPathComponent("a.md"))
        a.upsert(HistoryRecord(pdf: "/x/a.pdf", outdir: dir.path, startedAt: Date(), state: "running"))
        let b = History(url: h)     // 模拟崩溃后重启
        XCTAssertEqual(b.records[0].state, "interrupted")
        XCTAssertEqual(b.records[0].outputs.count, 1)
    }

    // MARK: 报告

    func testReportParse() {
        let b = ReportDocument.parse("# 标题\n\n- 源文件: x\n\n## 1　识别\n\n| 项 | 值 |\n|---|---|\n| 页数 | 3 |\n\n> 说明\n\n## 2　白页\n\n普通段\n")
        let s = ReportDocument.sections(b)
        XCTAssertEqual(s.map(\.title), ["概览", "1　识别", "2　白页"])
        XCTAssertTrue(s[1].blocks.contains(.table(header: ["项", "值"], rows: [["页数", "3"]])))
        XCTAssertTrue(s[1].blocks.contains(.quote("说明")))
    }

    func testRealReportSectionsPresent() {
        let t = """
        ## 1　识别与融合
        | 项 | 值 |
        |---|---|
        | 页数 | 1 |
        ## 2　白页闸门
        | 处理 | 页 |
        |---|---|
        | 无墨迹 | 无 |
        """
        XCTAssertEqual(ReportDocument.sections(ReportDocument.parse(t)).count, 2)
    }
}
