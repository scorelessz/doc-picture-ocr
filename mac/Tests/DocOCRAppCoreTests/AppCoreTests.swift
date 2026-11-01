import DocOCRAppCore
import Foundation
import OCRCore
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

    init(status: Int = 200, models: [String]? = nil, raw: Data? = nil) {
        let o: [String: Any] = models.map { ["data": $0.map { ["id": $0] }] } ?? ["choices": [["message": ["content": "读到的字"]]]]
        reply = HTTPReply(status: status, body: raw ?? (try! JSONSerialization.data(withJSONObject: o)))
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

    func prepare(preset: ProviderPreset, model: String, pdf: URL, forceOCR: Bool, pagesSpec: String?, workdir: URL) async throws -> OnlinePlan {
        let bodies = dir.appendingPathComponent(pdf.lastPathComponent + ".upload", isDirectory: true)
        try FileManager.default.createDirectory(at: bodies, withIntermediateDirectories: true)
        let f = bodies.appendingPathComponent("p1.json")
        try Data(count: 10).write(to: f)
        let pages = [OnlinePage(id: "p1", sourceFile: pdf.lastPathComponent, page: 1, body: f, bytes: 10)]
        let ep = try Endpoint(preset.baseURL)
        return OnlinePlan(preset: preset, endpoint: ep, model: model, pages: pages,
                          manifest: onlineManifest(pages, providerID: preset.id, providerName: preset.name, host: ep.host, model: model), bodies: bodies)
    }

    func adjudicationPlan(doc: FusedDoc, pdf: URL, preset: ProviderPreset, model: String, mode: AdjudicationMode, bodies: URL) async throws -> AdjudicationPlan {
        try AdjudicationPlan.build(doc: doc, source: pdf.lastPathComponent, preset: preset, model: model, mode: mode, bodies: bodies) { _, _ in Data([1]) }
    }

    /// 裁决挂钩要在工作线程上调，和 runBook 一样
    var fused: FusedDoc?
    nonisolated(unsafe) var last: BookOptions?
    private(set) var adjudicated: AdjudicationSummary?

    func run(_ opts: BookOptions, plan: OnlinePlan?, ticket: UploadTicket?, app: BackendContext) async throws -> BookResult {
        lock.lock(); ran.append(opts.pdf); last = opts; lock.unlock()
        if opts.isCancelled?() == true { throw BookError.cancelled }
        if let error { throw error }
        var o = opts
        if let hook = opts.adjudicate, let doc = fused {
            nonisolated(unsafe) let h = hook
            let r = try await Task.detached { try h(doc) }.value
            adjudicated = r?.1
            o.adjudicate = nil
        }
        if let plan, let ticket {
            try plan.attach(to: &o, transport: app.transport, key: app.key, ticket: ticket)
            let f = o.vlmOnline
            try await Task.detached { [f] in
                do { _ = try f?(1) } catch OnlineError.http { }     // 真流程里这是一页降级，不是任务失败
            }.value
        }
        var r = BookResult()
        r.adjudication = adjudicated
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
        try s.save("sk-test", for: "dashscope")
        if network { a.allowNetwork() } else { a.chooseLocalOnly() }
        let b = FakeBackend(dir: dir)
        let q = QueueModel(app: a, backend: b, modelsDir: try models(), vlDirectory: dir.appendingPathComponent("vl"), history: History(url: dir.appendingPathComponent("h.json")), prefs: Mem(), outdir: dir)
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
        try? s.save("k", for: qwen.id)
        let p = ProviderSettings(app: a)
        p.models[qwen.id] = "m"
        XCTAssertTrue(p.canTest(qwen))
        a.turnOffNetwork()
        XCTAssertFalse(p.canTest(qwen))
    }

    func testTestConnectionNeedsSelection() {
        let s = MemorySecretStore(), w = CountingWire(), a = AppModel(store: Mem(), wire: w, secrets: s)
        a.allowNetwork()
        try? s.save("k", for: qwen.id)
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
        try r.secrets.delete("dashscope")
        r.q.add([pdf("a")])
        r.q.start()
        await r.q.waitUntilIdle()
        guard case .failed = r.q.jobs[0].status else { return XCTFail() }
        XCTAssertEqual(r.wire.count, 0)
    }

    func testProviderFailureNeverSwitches() async throws {
        let r = try rig(status: 401)
        r.app.setSelected(ProviderPresets.find("deepseek")!, true)     // 另一家也选中、也有 Key
        try r.secrets.save("k", for: "deepseek")
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

    func testVLDirectoryIsNeverInsideBundledModels() {
        let q = QueueModel(app: AppModel(store: Mem(), wire: CountingWire(), secrets: MemorySecretStore()), backend: FakeBackend(dir: dir),
                           modelsDir: dir, history: History(url: dir.appendingPathComponent("h.json")), prefs: Mem(), outdir: dir)
        XCTAssertFalse(q.vlDirectory.path.hasPrefix(dir.path))
        XCTAssertTrue(q.vlDirectory.path.contains("Application Support"))
    }

    func testBundledModelsCannotBeManaged() throws {
        let m = ModelManager(dir: dir, bundled: try models())
        XCTAssertTrue(m.isBundled(.coreml))
        XCTAssertFalse(m.isBundled(.vl))
        XCTAssertTrue(m.installed(.coreml))
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

    // MARK: 高级选项与部分页

    func testAdvancedOptionsReachBook() async throws {
        let r = try rig(online: false)
        r.q.unitsLabel = "cpu"
        r.q.vlmAll = true
        r.q.vlmBreaks = true
        r.q.keepPages = true
        r.q.pagesText = " 2-3 "
        r.q.add([pdf("a")])
        r.q.start()
        await r.q.waitUntilIdle()
        let o = try XCTUnwrap(r.backend.last)
        XCTAssertEqual(o.units, .cpuOnly)
        XCTAssertEqual(o.unitsLabel, "cpu")
        XCTAssertTrue(o.vlmAll && o.vlmBreaks && o.keepPages)
        XCTAssertEqual(o.pagesSpec, "2-3")
    }

    func testDefaultsAreConservative() async throws {
        let r = try rig(online: false)
        r.q.add([pdf("a")])
        r.q.start()
        await r.q.waitUntilIdle()
        let o = try XCTUnwrap(r.backend.last)
        XCTAssertEqual(o.units, .cpuAndNeuralEngine)
        XCTAssertFalse(o.vlmAll || o.vlmBreaks || o.keepPages)
        XCTAssertNil(o.pagesSpec)
    }

    func testPreferencesPersist() throws {
        let p = Mem(), a = AppModel(store: Mem(), wire: CountingWire(), secrets: MemorySecretStore())
        func q() throws -> QueueModel {
            QueueModel(app: a, backend: FakeBackend(dir: dir), modelsDir: try models(), history: History(url: dir.appendingPathComponent("p.json")), prefs: p, outdir: dir)
        }
        let one = try q()
        one.unitsLabel = "gpu"
        one.localURL = "http://127.0.0.1:1234/v1"
        XCTAssertEqual(try q().unitsLabel, "gpu")
        XCTAssertEqual(try q().localURL, "http://127.0.0.1:1234/v1")
    }

    func testBadPageSpecBlocksStart() throws {
        let r = try rig(online: false)
        r.q.add([pdf("a")])
        r.q.pagesText = "abc"
        XCTAssertFalse(r.q.canStart)
        r.q.pagesText = "1-3,7"
        XCTAssertTrue(r.q.canStart)
    }

    func testLocalServiceOnlyLoopbackAndNeedsNoNetwork() async throws {
        let r = try rig(network: false, online: false)
        r.q.add([pdf("a")])
        r.q.highPrecision = true
        r.q.useLocalService = true
        XCTAssertFalse(r.q.needsVLModel, "本机服务不需要进程内模型")
        r.q.localURL = "https://api.example.com/v1"
        r.q.localModel = "m"
        XCTAssertNil(r.q.localEndpoint)
        XCTAssertFalse(r.q.canStart)
        r.q.localURL = "http://127.0.0.1.evil.com/v1"
        XCTAssertNil(r.q.localEndpoint)
        r.q.localURL = "http://192.168.1.2:11434/v1"
        XCTAssertNil(r.q.localEndpoint)
        r.q.localURL = "http://127.0.0.1:11434/v1"
        XCTAssertTrue(r.q.canStart, "总开关关着也能用")
        r.q.start()
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.backend.last?.vlmURL?.absoluteString, "http://127.0.0.1:11434/v1")
        XCTAssertNil(r.q.confirm)
        XCTAssertEqual(r.wire.count, 0)
    }

    // MARK: 在线裁决

    private func fusedDoc() throws -> FusedDoc {
        let line = "{\"x\":1,\"y\":2,\"w\":3,\"h\":4,\"text\":\"甲\",\"conf\":1,\"src\":\"both\",\"alt\":\"乙\",\"flag\":\"divergent\"}"
        let stats = "{\"pages\":1,\"lines\":1,\"both\":1,\"divergent\":1,\"only_vision\":0,\"only_rapidocr\":0,\"low_conf\":0,\"glossary_hits\":0,\"dropped_empty\":0,\"dropped_contained\":0}"
        let j = "{\"source\":\"a.pdf\",\"engines\":[\"vision\",\"rapidocr\"],\"stats\":\(stats),\"dpi\":300,\"pages\":[{\"page\":1,\"width\":100,\"height\":100,\"pdf_width\":50,\"pdf_height\":50,\"zoom\":2,\"rotation\":0,\"native_text\":false,\"lines\":[\(line)]}]}"
        return try JSONDecoder().decode(FusedDoc.self, from: Data(j.utf8))
    }

    private func adjRig(network: Bool = true, select: Bool = true, reply: String = "{\"choice\": 0}") throws -> Rig {
        let r = try rig(network: network, online: false)
        r.backend.fused = try fusedDoc()
        if select { r.app.setSelected(qwen, true) }
        r.q.adjudicateOn = true
        r.q.adjudicateMode = .text
        r.q.adjudicateProviderID = "dashscope"
        r.q.adjudicateModel = "m"
        r.q.add([pdf("a")])
        return r
    }

    func testAdjudicationOffByDefault() throws {
        let r = try rig(online: false)
        XCTAssertFalse(r.q.adjudicateOn)
        XCTAssertFalse(r.q.adjudicateReady)
    }

    func testAdjudicationBlockedWhenNetworkOff() throws {
        let r = try adjRig(network: false)
        XCTAssertFalse(r.q.adjudicateReady)
        XCTAssertEqual(r.q.blockReason, AppModel.offReason)
        XCTAssertFalse(r.q.canStart)
        XCTAssertTrue(r.q.adjudicateProviders.isEmpty)
    }

    func testAdjudicationNeedsSelectedProvider() async throws {
        let r = try adjRig(select: false)
        XCTAssertFalse(r.q.adjudicateReady)
        XCTAssertFalse(r.q.canStart, "有 Key 但没选中")
        r.q.start()
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.wire.count, 0)
    }

    func testAdjudicationNeedsReadableKey() throws {
        let r = try adjRig()
        XCTAssertTrue(r.q.adjudicateReady)
        r.secrets.locked = ["dashscope"]
        XCTAssertFalse(r.q.adjudicateReady, "读不了的 Key 不算有 Key")
    }

    func testImageModeHidesTextOnlyProviders() throws {
        let r = try adjRig()
        let d = ProviderPresets.find("deepseek")!
        r.app.setSelected(d, true)
        try r.secrets.save("k", for: "deepseek")
        XCTAssertTrue(r.q.adjudicateProviders.contains(d))
        r.q.adjudicateMode = .image
        XCTAssertFalse(r.q.adjudicateProviders.contains(d))
    }

    func testAdjudicationAwaitingConfirmZeroRequests() async throws {
        let r = try adjRig()
        r.q.start()
        await until { r.q.confirm != nil }
        XCTAssertEqual(r.wire.count, 0)
        XCTAssertEqual(r.q.confirm?.contentText, "1 处分歧，约 2 字，不传图片")
        XCTAssertEqual(r.q.confirm?.host, "dashscope.aliyuncs.com")
        r.q.confirmUpload(checkbox: false, forBatch: false)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(r.wire.count, 0)
        r.q.declineUpload()
        await r.q.waitUntilIdle()
    }

    func testAdjudicationDeclineKeepsLocalResult() async throws {
        let r = try adjRig()
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.declineUpload()
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.wire.count, 0)
        XCTAssertEqual(r.q.jobs[0].status, .done, "本地结果保留，任务算完成")
        XCTAssertEqual(r.q.jobs[0].record?.adjudication?.declined, true)
    }

    func testAdjudicationConfirmedSendsOnlyDivergentLines() async throws {
        let r = try adjRig()
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.confirmUpload(checkbox: true, forBatch: false)
        await r.q.waitUntilIdle()
        XCTAssertEqual(r.wire.count, 1)
        XCTAssertEqual(r.q.jobs[0].record?.adjudication?.total, 1)
        XCTAssertEqual(r.q.jobs[0].status, .done)
    }

    func testAdjudicationBodiesAreRemoved() async throws {
        let r = try adjRig()
        r.q.start()
        await until { r.q.confirm != nil }
        r.q.declineUpload()
        await r.q.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".work/a/adjudication").path))
    }

    // MARK: Key 状态

    private func keyRig() -> (MemorySecretStore, ProviderSettings, AppModel, CountingWire) {
        let s = MemorySecretStore(), w = CountingWire(), a = AppModel(store: Mem(), wire: w, secrets: s)
        a.allowNetwork()
        a.setSelected(qwen, true)
        return (s, ProviderSettings(app: a, store: Mem(), profileDir: dir.appendingPathComponent("prof")), a, w)
    }

    func testKeyStatesNeverShowPlaintext() throws {
        let (s, p, _, _) = keyRig()
        XCTAssertEqual(p.keyLine("dashscope"), "未设置")
        try s.save("sk-abcdefghij-secret", for: "dashscope")
        let line = p.keyLine("dashscope")
        XCTAssertTrue(line.hasPrefix("已保存（本 App 可读）sk-a…，共 20 位"), line)
        XCTAssertFalse(line.contains("abcdefghij"))
        s.locked = ["dashscope"]
        XCTAssertTrue(p.keyLine("dashscope").hasPrefix("已保存但需授权"))
        XCTAssertTrue(p.needsAuthorization("dashscope"))
        XCTAssertFalse(p.keyLine("dashscope").contains("sk-a"))
    }

    func testLockedKeyCanBeOverwritten() throws {
        let (s, p, _, _) = keyRig()
        try s.save("old", for: "dashscope")
        s.locked = ["dashscope"]
        p.saveKey("new-key", for: "dashscope")
        XCTAssertTrue(p.result["dashscope"]?.contains("覆盖") == true)
        XCTAssertTrue(p.hasKey("dashscope"))
    }

    func testUndeletableOldEntryExplainsWhatToDo() throws {
        let (s, p, _, _) = keyRig()
        try s.save("old", for: "dashscope")
        s.undeletable = ["dashscope"]
        p.saveKey("new-key", for: "dashscope")
        XCTAssertTrue(p.result["dashscope"]?.contains("钥匙串访问") == true)
    }

    func testAuthorizeUnlocks() async throws {
        let (s, p, _, _) = keyRig()
        try s.save("old", for: "dashscope")
        s.locked = ["dashscope"]
        p.authorize("dashscope")
        await until { p.result["dashscope"] == "授权成功" }
        XCTAssertTrue(p.hasKey("dashscope"))
    }

    func testLockedKeyBlocksRequests() async throws {
        let (s, p, _, w) = keyRig()
        try s.save("old", for: "dashscope")
        s.locked = ["dashscope"]
        p.models["dashscope"] = "m"
        XCTAssertFalse(p.canTest(qwen))
        await p.refreshModels(qwen)
        XCTAssertEqual(w.count, 0)
    }

    // MARK: 模型列表

    func testModelFilterListsEverything() {
        let o = ModelFilter.options(ids: ["z-chat", "text-embedding-3", "qwen-vl-ocr", "m-bad", "m-good"], profiles: [
            CapabilityProfile(providerID: "p", model: "m-bad", probedAt: Date(), supportsImage: false, responseFormat: .text),
            CapabilityProfile(providerID: "p", model: "m-good", probedAt: Date(), supportsImage: true, responseFormat: .text),
        ], recommended: "rec")
        XCTAssertEqual(o.map(\.id), ["rec", "m-good", "qwen-vl-ocr", "z-chat", "text-embedding-3", "m-bad"])
        XCTAssertEqual(o.map(\.status), [.recommended, .verified, .unverified, .unverified, .unverified, .unsupported])
    }

    private func listRig(wire: CountingWire, network: Bool = true, select: Bool = true, key: Bool = true) throws -> (ProviderSettings, CountingWire) {
        let s = MemorySecretStore(), a = AppModel(store: Mem(), wire: wire, secrets: s)
        if key { try s.save("k", for: qwen.id) }
        if network { a.allowNetwork() }
        if select { a.setSelected(qwen, true) }
        return (ProviderSettings(app: a, store: Mem(), profileDir: dir.appendingPathComponent("prof-\(UUID().uuidString)")), wire)
    }

    func testLongListIsFullySelectable() async throws {
        let ids = (0..<184).map { "qwen-model-\($0)" } + ["qwen3.7-flash", "qwen3.7-flash-2026-07-15"]
        let (p, w) = try listRig(wire: CountingWire(models: ids))
        await p.refreshModels(qwen)
        XCTAssertEqual(w.count, 1)
        let all = p.options(qwen)
        XCTAssertEqual(all.count, 186, "不能截断，也不能只留推荐和已验证")
        XCTAssertEqual(all.first?.id, "qwen3.7-flash")
        XCTAssertNil(p.listError["dashscope"])
    }

    func testCurrentModelNameDoesNotFilterList() async throws {
        let (p, _) = try listRig(wire: CountingWire(models: ["a", "b", "qwen3.7-flash", "qwen3.7-flash-x"]))
        await p.refreshModels(qwen)
        XCTAssertEqual(p.models["dashscope"], "qwen3.7-flash")
        XCTAssertEqual(ModelFilter.search(p.options(qwen), "").count, 4, "搜索框是空的就显示全部")
        XCTAssertEqual(ModelFilter.search(p.options(qwen), " QWEN3.7 ").count, 2)
    }

    func testListFailureIsShownAndKeepsCache() async throws {
        let (p, _) = try listRig(wire: CountingWire(models: ["a", "b"]))
        await p.refreshModels(qwen)
        XCTAssertEqual(p.options(qwen).count, 3)
        let bad = CountingWire(status: 401)
        let s = MemorySecretStore(), a = AppModel(store: Mem(), wire: bad, secrets: s), d = dir.appendingPathComponent("prof-keep")
        try ProfileStore.saveModels(CachedModels(fetchedAt: Date(), ids: ["a", "b"]), for: qwen.id, in: d)
        try s.save("k", for: qwen.id)
        a.allowNetwork()
        a.setSelected(qwen, true)
        let q = ProviderSettings(app: a, store: Mem(), profileDir: d)
        await q.refreshModels(qwen)
        XCTAssertTrue(q.listError["dashscope"]?.contains("401") == true)
        XCTAssertEqual(q.options(qwen).count, 3, "失败时保留缓存")
    }

    func testListBadBodyAndEmptyAreReported() async throws {
        let (p, _) = try listRig(wire: CountingWire(raw: Data("<html>".utf8)))
        await p.refreshModels(qwen)
        XCTAssertNotNil(p.listError["dashscope"])
        let (q, _) = try listRig(wire: CountingWire(models: []))
        await q.refreshModels(qwen)
        XCTAssertEqual(q.listError["dashscope"], "服务商返回了空列表")
    }

    func testRetryClearsError() async throws {
        let (p, _) = try listRig(wire: CountingWire(models: ["a"]), key: false)
        await p.refreshModels(qwen)
        XCTAssertEqual(p.listError["dashscope"], "还没有填 Key")
        p.saveKey("k", for: "dashscope")
        await p.refreshModels(qwen)
        XCTAssertNil(p.listError["dashscope"])
    }

    func testNoKeyZeroRequests() async throws {
        let (p, w) = try listRig(wire: CountingWire(models: ["a"]), key: false)
        await p.refreshModels(qwen)
        XCTAssertEqual(w.count, 0)
    }

    func testNetworkOffZeroRequestsAndSaysWhy() async throws {
        let (p, w) = try listRig(wire: CountingWire(models: ["a"]), network: false, select: false)
        await p.refreshModels(qwen)
        XCTAssertEqual(w.count, 0)
        XCTAssertEqual(p.listError["dashscope"], AppModel.offReason)
    }

    func testRecommendedDefaultsAndDeepSeekTextOnly() {
        let a = AppModel(store: Mem(), wire: CountingWire(), secrets: MemorySecretStore())
        let p = ProviderSettings(app: a, store: Mem(), profileDir: dir)
        XCTAssertEqual(p.models["dashscope"], "qwen3.7-flash")
        XCTAssertEqual(p.models["siliconflow"], "Qwen/Qwen3-VL-32B-Instruct")
        XCTAssertEqual(p.models["deepseek"], "deepseek-flash")
        a.allowNetwork()
        for x in ProviderPresets.all { a.setSelected(x, true) }
        XCTAssertFalse(a.readableProviders.contains { $0.id == "deepseek" })
        XCTAssertTrue(a.readableProviders.contains { $0.id == "dashscope" })
    }

    func testNoAutoFetchWhenOffOrUnselected() async throws {
        let s = MemorySecretStore(), w = CountingWire(), a = AppModel(store: Mem(), wire: w, secrets: s)
        try s.save("k", for: "dashscope")
        let p = ProviderSettings(app: a, store: Mem(), profileDir: dir.appendingPathComponent("prof"))
        await p.refreshAll()                // 总开关关
        a.allowNetwork()
        await p.refreshAll()                // 开了，但没选中（有 Key 也不算）
        XCTAssertEqual(w.count, 0)
        a.setSelected(qwen, true)
        await p.refreshModels(qwen)
        XCTAssertEqual(w.count, 1, "选中后只发一次 GET /models")
    }

    func testCachedListShownWhenOffline() throws {
        let d = dir.appendingPathComponent("prof")
        try ProfileStore.saveModels(CachedModels(fetchedAt: Date(), ids: ["a"]), for: "dashscope", in: d)
        let a = AppModel(store: Mem(), wire: CountingWire(), secrets: MemorySecretStore())
        let p = ProviderSettings(app: a, store: Mem(), profileDir: d)
        XCTAssertTrue(p.options(qwen).contains { $0.id == "a" })
        XCTAssertTrue(p.listNote(qwen)?.contains("没有联网") == true)
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
