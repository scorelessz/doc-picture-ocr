import Combine
import Foundation
import OCRCore
import OCREngines
import OCRProviders
import OCRVL

// 批处理队列。一次只跑一份，工作在后台线程，界面只看状态。业务全部走 runBook。

public enum JobStatus: Equatable, Sendable {
    case queued, preparing, awaitingConfirm
    case running(stage: String, done: Int, total: Int)
    case done, failed(String), cancelled, declined
}

public struct Job: Identifiable, Equatable, Sendable {
    public let id: UUID, pdf: URL
    public var status: JobStatus = .queued
    public var record: HistoryRecord?

    public init(pdf: URL) { id = UUID(); self.pdf = pdf }
}

public struct HistoryRecord: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var pdf: String, outdir: String, startedAt: Date
    public var state: String          // running / done / failed / cancelled / interrupted
    public var outputs: [String] = []
    public var report: String?
    public var pages = 0, secPerPage = 0.0
    public var degraded: [String] = []
    public var adjudication: AdjudicationSummary?

    public init(pdf: String, outdir: String, startedAt: Date, state: String) {
        self.pdf = pdf; self.outdir = outdir; self.startedAt = startedAt; self.state = state
    }
}

/// 产物写在 outdir，这里只记路径。崩溃后 running 记录改成 interrupted，已写出的产物照样列出来。
public final class History: @unchecked Sendable {
    private let url: URL, lock = NSLock()
    public private(set) var records: [HistoryRecord] = []

    public init(url: URL) {
        self.url = url
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        records = (try? dec.decode([HistoryRecord].self, from: Data(contentsOf: url))) ?? []
        for i in records.indices where records[i].state == "running" {
            records[i].state = "interrupted"
            let stem = URL(fileURLWithPath: records[i].pdf).deletingPathExtension().lastPathComponent
            records[i].outputs = [".md", ".searchable.pdf", ".report.md"].map { records[i].outdir + "/" + stem + $0 }
                .filter { FileManager.default.fileExists(atPath: $0) }
        }
    }

    public func upsert(_ r: HistoryRecord) {
        lock.lock()
        defer { lock.unlock() }
        if let i = records.firstIndex(where: { $0.id == r.id }) { records[i] = r } else { records.insert(r, at: 0) }
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? enc.encode(records).write(to: url, options: .atomic)
    }
}

public struct ConfirmRequest: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case pages
        case adjudication(lines: Int, chars: Int, crops: Int)
    }

    public let manifest: UploadManifest, fileName: String, kind: Kind

    public init(manifest: UploadManifest, fileName: String, kind: Kind = .pages) {
        self.manifest = manifest; self.fileName = fileName; self.kind = kind
    }

    public var providerName: String { manifest.providerName }
    public var host: String { manifest.host }
    public var pages: Int { manifest.items.count }
    public var megabytes: Double { Double(manifest.totalBytes) / 1_048_576 }
    public var costText: String {
        if case .estimated(let s) = manifest.estimatedCost { return s }
        return "未知"
    }
    public var contentText: String {
        switch kind {
        case .pages: return "最多 \(pages) 页（有分歧的页才发送）"
        case let .adjudication(n, m, k):
            return "\(n) 处分歧，约 \(m) 字" + (k > 0 ? " / \(k) 张裁切图" : "，不传图片")
        }
    }
    public var contentLabel: String { kind == .pages ? "页数" : "内容" }
    public var cancelTitle: String { kind == .pages ? "取消，不上传" : "不上传，只保留本地结果" }
    public var checkboxLabel: String {
        switch kind {
        case .pages: return "我确认将以上 \(pages) 页图片上传到 \(host)"
        case let .adjudication(n, _, _): return "我确认将以上 \(n) 处分歧上传到 \(host)"
        }
    }
}

/// 可替换的后端，单测用假的。
public protocol BookBackend: Sendable {
    func prepare(preset: ProviderPreset, model: String, pdf: URL, forceOCR: Bool, pagesSpec: String?, workdir: URL) async throws -> OnlinePlan
    func adjudicationPlan(doc: FusedDoc, pdf: URL, preset: ProviderPreset, model: String, mode: AdjudicationMode, bodies: URL) async throws -> AdjudicationPlan
    func run(_ o: BookOptions, plan: OnlinePlan?, ticket: UploadTicket?, app: BackendContext) async throws -> BookResult
}

/// runBook 是同步的，挂钩在工作线程上等异步结果
private func blocking<T: Sendable>(_ f: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: Result<T, Error>?
    Task.detached {
        do { out = .success(try await f()) } catch { out = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try out!.get()
}

public struct BackendContext: Sendable {
    public let transport: HTTPTransport, key: SecretKey?, vl: VLHandle?
}

/// 进程内 VLM 只载入一次，批次结束释放。
public final class VLHandle: @unchecked Sendable {
    let vl: PaddleVL
    public init(directory: URL) throws { vl = try PaddleVL(directory: directory) }
    public func read(_ px: [UInt8], _ w: Int, _ h: Int) -> String { vl.read(px, w: w, h: h).text }
}

public struct LocalBackend: BookBackend {
    public init() {}

    public func prepare(preset: ProviderPreset, model: String, pdf: URL, forceOCR: Bool, pagesSpec: String?, workdir: URL) async throws -> OnlinePlan {
        try await Task.detached { try OnlinePlan.prepare(preset: preset, model: model, pdf: pdf, forceOCR: forceOCR, pagesSpec: pagesSpec, workdir: workdir, log: { _ in }) }.value
    }

    public func adjudicationPlan(doc: FusedDoc, pdf: URL, preset: ProviderPreset, model: String, mode: AdjudicationMode, bodies: URL) async throws -> AdjudicationPlan {
        try AdjudicationPlan.prepare(doc: doc, pdf: mode == .image ? pdf : nil, source: pdf.lastPathComponent, preset: preset, model: model, mode: mode, bodies: bodies)
    }

    public func run(_ o: BookOptions, plan: OnlinePlan?, ticket: UploadTicket?, app: BackendContext) async throws -> BookResult {
        nonisolated(unsafe) let opts = o
        return try await Task.detached(priority: .userInitiated) {
            var o = opts
            if let vl = app.vl { o.vlmLocal = { vl.read($0, $1, $2) } }
            if let plan, let ticket { try plan.attach(to: &o, transport: app.transport, key: app.key, ticket: ticket) }
            return try runBook(o) { _ in }
        }.value
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}

@MainActor
public final class QueueModel: ObservableObject {
    public static let highPrecisionNote = "普通模式：两个本地引擎交叉核对，整本约 3 分钟，错误率约 0.5%。\n高精度模式：再加本地大模型逐页投票，错误率再降约 0.05–0.1 个百分点（中文 0.49% → 0.40%，英文 0.50% → 0.45%），但整本约 1 小时（慢约 20 倍），内存多约 1–3 GB。不赶时间、要求逐字精确时再开。"

    @Published public private(set) var jobs: [Job] = []
    @Published public var makeMarkdown = true
    @Published public var makePDF = true
    @Published public var pageMarks = "comment"
    @Published public var outdir: URL
    @Published public var overwrite = false
    @Published public var forceOCR = false
    @Published public var highPrecision = false
    @Published public var onlineProviderID: String?
    @Published public var onlineModel = ""
    /// 留空表示全部页
    @Published public var pagesText = ""
    // 下面这些是设置页里的选项，要记住
    @Published public var unitsLabel: String { didSet { prefs.set(unitsLabel, "units") } }
    @Published public var vlmAll: Bool { didSet { prefs.set(vlmAll ? "1" : "0", "vlmAll") } }
    @Published public var vlmBreaks: Bool { didSet { prefs.set(vlmBreaks ? "1" : "0", "vlmBreaks") } }
    @Published public var keepPages: Bool { didSet { prefs.set(keepPages ? "1" : "0", "keepPages") } }
    @Published public var useLocalService: Bool { didSet { prefs.set(useLocalService ? "1" : "0", "useLocalService") } }
    @Published public var localURL: String { didSet { prefs.set(localURL, "localURL") } }
    @Published public var localModel: String { didSet { prefs.set(localModel, "localModel") } }
    @Published public var adjudicateOn = false
    @Published public var adjudicateMode: AdjudicationMode = .image
    @Published public var adjudicateProviderID: String?
    @Published public var adjudicateModel = ""
    @Published public private(set) var isRunning = false
    @Published public private(set) var confirm: ConfirmRequest?
    @Published public private(set) var history: [HistoryRecord]

    private let app: AppModel, backend: BookBackend, modelsDir: URL, store: History, prefs: KVStore
    /// VL 模型按需下载，App 包只读，永远在 Application Support
    public let vlDirectory: URL
    private var worker: Task<Void, Never>?
    private var cancelFlag = Flag()
    private var batchID = UUID()
    private var answer: CheckedContinuation<(Bool, Scope?), Never>?

    public init(app: AppModel, backend: BookBackend = LocalBackend(), modelsDir: URL = ModelStore.resolvedDirectory,
                vlDirectory: URL = VLModel.directory(models: ModelStore.defaultDirectory),
                history: History = History(url: AppPaths.history), prefs: KVStore = DefaultsStore(), outdir: URL) {
        self.vlDirectory = vlDirectory
        self.prefs = prefs
        unitsLabel = prefs.string("units") ?? "ane"
        vlmAll = prefs.string("vlmAll") == "1"
        vlmBreaks = prefs.string("vlmBreaks") == "1"
        keepPages = prefs.string("keepPages") == "1"
        useLocalService = prefs.string("useLocalService") == "1"
        localURL = prefs.string("localURL") ?? ""
        localModel = prefs.string("localModel") ?? ""
        self.app = app; self.backend = backend; self.modelsDir = modelsDir; self.store = history; self.outdir = outdir
        self.history = history.records
    }

    public var vlInstalled: Bool { FileManager.default.fileExists(atPath: vlDirectory.appendingPathComponent("model.safetensors").path) }
    public var needsVLModel: Bool { highPrecision && !useLocalService && !vlInstalled }
    private var pagesSpec: String? {
        let t = pagesText.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : t
    }

    /// 只接受本机地址，不走上传确认，不受总开关限制
    public var localEndpoint: Endpoint? { (try? Endpoint(localURL)).flatMap { $0.isLoopback ? $0 : nil } }
    public var pageDirectory: URL { outdir.appendingPathComponent(".work", isDirectory: true) }
    public var coreMLInstalled: Bool { ModelStore.installed(modelsDir) }

    /// 总开关关掉或取消选中后，在线读字自动失效
    public var onlineEnabled: Bool { onlineProviderID.map(app.isUsable) == true && !onlineModel.isEmpty }

    public var adjudicateProviders: [ProviderPreset] { app.adjudicationProviders(adjudicateMode) }

    /// 总开关关掉、取消选中、Key 没了，都自动失效
    public var adjudicateReady: Bool {
        adjudicateOn && !adjudicateModel.isEmpty && adjudicateProviders.contains { $0.id == adjudicateProviderID }
    }

    public var blockReason: String? {
        if !makeMarkdown, !makePDF { return "至少选一种产物" }
        if let s = pagesSpec, (try? parsePages(s, count: .max)) == nil { return "页范围写法不对，例如 1-20 或 3,5,8" }
        if highPrecision, useLocalService {
            if localEndpoint == nil { return "本机服务只接受本机地址，例如 http://127.0.0.1:11434/v1" }
            if localModel.isEmpty { return "本机服务要填模型名" }
        }
        if !coreMLInstalled { return "还没有识别模型，请到设置 → 模型下载" }
        if needsVLModel { return "高精度模式需要 VL 模型，请到设置 → 模型下载" }
        if highPrecision, onlineEnabled { return "高精度模式和在线读字只能选一个" }
        if onlineProviderID != nil, !onlineEnabled { return app.networkAllowed ? "在线读字要选中服务商并填模型名" : AppModel.offReason }
        if adjudicateOn, !adjudicateReady { return app.networkAllowed ? "在线裁决要选服务商和模型" : AppModel.offReason }
        return nil
    }

    public var canStart: Bool { !isRunning && blockReason == nil && jobs.contains { $0.status == .queued } }

    public func add(_ urls: [URL]) {
        var have = Set(jobs.map(\.pdf))
        jobs += urls.filter { $0.pathExtension.lowercased() == "pdf" && have.insert($0).inserted }.map(Job.init)
    }

    public func remove(_ id: UUID) { jobs.removeAll { $0.id == id && [.queued, .done, .cancelled, .declined].contains($0.status) || $0.id == id && isFailed($0) } }

    private func isFailed(_ j: Job) -> Bool {
        if case .failed = j.status { return true }
        return false
    }

    private func set(_ id: UUID, _ s: JobStatus) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].status = s }
    }

    public func start() {
        guard canStart else { return }
        isRunning = true
        cancelFlag = Flag()
        worker = Task { [weak self] in
            await self?.runAll()
        }
    }

    /// 取消当前任务：停在下一个检查点。排队中的不再开始。
    public func cancel() {
        cancelFlag.value = true
        answer?.resume(returning: (false, nil))
        answer = nil
    }

    /// 复选框没勾什么都不发生。「本批次内不再询问」只在内存里，批次结束就没了。
    public func confirmUpload(checkbox: Bool, forBatch: Bool) {
        guard checkbox, let a = answer else { return }
        answer = nil
        a.resume(returning: (true, forBatch ? .batch(batchID) : .once))
    }

    public func declineUpload() {
        answer?.resume(returning: (false, nil))
        answer = nil
    }

    public func waitUntilIdle() async { await worker?.value }

    private func runAll() async {
        defer { isRunning = false; confirm = nil }
        var vl: VLHandle?
        if highPrecision, !useLocalService { vl = try? await Task.detached { [dir = vlDirectory] in try VLHandle(directory: dir) }.value }
        batchID = UUID()
        while let i = jobs.firstIndex(where: { $0.status == .queued }) {
            if cancelFlag.value { break }
            let goOn = await run(jobs[i], vl: vl)
            await app.gate.finish()
            if !goOn { break }
        }
        await app.gate.finishBatch()
    }

    /// 返回 false 时停止整批
    private func run(_ job: Job, vl: VLHandle?) async -> Bool {
        let stem = job.pdf.deletingPathExtension().lastPathComponent
        let work = outdir.appendingPathComponent(".work/\(stem)", isDirectory: true)
        var plan: OnlinePlan?, ticket: UploadTicket?, key: SecretKey?
        if onlineEnabled, let id = onlineProviderID, let preset = ProviderPresets.find(id) {
            set(job.id, .preparing)
            do {
                key = try app.secrets.load(id)
                guard key != nil else { throw BookError.failed("没有 \(preset.name) 的 Key，请到设置里填写") }
                let p = try await backend.prepare(preset: preset, model: onlineModel, pdf: job.pdf, forceOCR: forceOCR, pagesSpec: pagesSpec, workdir: work)
                let st = await app.gate.request(p.manifest)
                if case .confirmed(let t) = st {        // 同一批次、同一域名
                    ticket = t
                } else {
                    set(job.id, .awaitingConfirm)
                    confirm = ConfirmRequest(manifest: p.manifest, fileName: job.pdf.lastPathComponent)
                    let (ok, scope) = await withCheckedContinuation { self.answer = $0 }
                    confirm = nil
                    guard ok, let scope else {
                        p.discard()
                        await app.gate.decline()
                        set(job.id, cancelFlag.value ? .cancelled : .declined)
                        return false            // 不确认：任务不开始，也不降级成本地
                    }
                    ticket = try await app.gate.confirm(checkbox: true, scope: scope)
                }
                plan = p
            } catch {
                set(job.id, .failed("\(error)"))
                return true
            }
        }
        var o = BookOptions(pdf: job.pdf, outdir: outdir, workdir: work, python: "")
        o.md = makeMarkdown
        o.searchable = makePDF
        o.pageMarks = pageMarks
        o.force = overwrite
        o.forceOCR = forceOCR
        o.pagesSpec = pagesSpec
        o.keepPages = keepPages
        o.vlmAll = vlmAll
        o.vlmBreaks = vlmBreaks
        o.unitsLabel = unitsLabel
        o.units = computeUnits(unitsLabel) ?? .cpuAndNeuralEngine
        if highPrecision, useLocalService, let e = localEndpoint {
            o.vlmURL = e.baseURL
            o.vlmModel = localModel
        }
        o.coreml = modelsDir
        let flag = cancelFlag, id = job.id
        o.isCancelled = { flag.value }
        o.progress = { [weak self] stage, done, total in
            Task { @MainActor in self?.set(id, .running(stage: stage.rawValue, done: done, total: total)) }
        }
        if adjudicateReady, let id = adjudicateProviderID, let preset = ProviderPresets.find(id) {
            let k: SecretKey?
            do { k = try app.secrets.load(id) } catch {
                set(job.id, .failed("\(error)"))
                return true
            }
            let uploads = outdir.appendingPathComponent("\(stem).uploads.jsonl")
            o.uploadsPath = uploads
            o.adjudicate = adjudicationHook(job: job, preset: preset, key: k, work: work, uploads: uploads)
        }
        var rec = HistoryRecord(pdf: job.pdf.path, outdir: outdir.path, startedAt: Date(), state: "running")
        record(rec)
        set(job.id, .running(stage: BookStage.ocr.rawValue, done: 0, total: 0))
        do {
            let r = try await backend.run(o, plan: plan, ticket: ticket, app: BackendContext(transport: app.transport, key: key, vl: vl))
            rec.state = "done"
            rec.outputs = r.outputs
            rec.report = r.outputs.first { $0.hasSuffix(".report.md") }
            rec.pages = r.pages
            rec.secPerPage = r.secPerPage
            rec.degraded = r.degraded
            rec.adjudication = r.adjudication
            record(rec)
            await Task.yield()
            set(job.id, .done)
            attach(rec, to: job.id)
            return true
        } catch BookError.cancelled {
            plan?.discard()
            rec.state = "cancelled"
            record(rec)
            set(job.id, .cancelled)
            return false
        } catch {
            plan?.discard()
            rec.state = "failed"
            rec.degraded = ["\(error)"]
            record(rec)
            set(job.id, .failed("\(error)"))
            return true
        }
    }

    /// 本地 OCR 跑完后才知道有多少分歧。这里在工作线程上，问用户时界面不卡；不确认就只保留本地结果。
    private func adjudicationHook(job: Job, preset: ProviderPreset, key: SecretKey?, work: URL, uploads: URL) -> (FusedDoc) throws -> (FusedDoc, AdjudicationSummary)? {
        let (backend, app, model, mode, id, pdf) = (backend, app, adjudicateModel, adjudicateMode, job.id, job.pdf)
        let bodies = work.appendingPathComponent("adjudication", isDirectory: true)
        return { [weak self] doc in
            let plan = try blocking { try await backend.adjudicationPlan(doc: doc, pdf: pdf, preset: preset, model: model, mode: mode, bodies: bodies) }
            defer { plan.discard() }
            guard !plan.questions.isEmpty else { return (doc, plan.summary(AdjudicationOutcome(doc: doc))) }
            let ticket: UploadTicket? = try blocking { await self?.askAdjudication(plan, jobID: id, fileName: pdf.lastPathComponent) }
            guard let ticket else { return (doc, plan.declinedSummary()) }
            let transport = try blocking { await app.transport }
            let reader = OnlineReader(transport: transport, endpoint: plan.endpoint, providerID: preset.id, model: model, key: key,
                                      ticket: ticket, ledger: try FileLedger(uploads))
            let out = try blocking { await plan.run(doc, reader: reader) }
            return (out.doc, plan.summary(out))
        }
    }

    private func askAdjudication(_ plan: AdjudicationPlan, jobID: UUID, fileName: String) async -> UploadTicket? {
        let st = await app.gate.request(plan.manifest)
        if case .confirmed(let t) = st { return t }     // 同一批次、同一域名
        set(jobID, .awaitingConfirm)
        confirm = ConfirmRequest(manifest: plan.manifest, fileName: fileName,
                                 kind: .adjudication(lines: plan.questions.count, chars: plan.chars, crops: plan.crops))
        let (ok, scope) = await withCheckedContinuation { self.answer = $0 }
        confirm = nil
        set(jobID, .running(stage: BookStage.adjudicate.rawValue, done: 0, total: 0))
        guard ok, let scope else {
            await app.gate.decline()
            return nil
        }
        return try? await app.gate.confirm(checkbox: true, scope: scope)
    }

    private func record(_ r: HistoryRecord) {
        store.upsert(r)
        history = store.records
    }

    private func attach(_ r: HistoryRecord, to id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].record = r }
    }
}
