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
    public let manifest: UploadManifest, fileName: String

    public init(manifest: UploadManifest, fileName: String) { self.manifest = manifest; self.fileName = fileName }

    public var providerName: String { manifest.providerName }
    public var host: String { manifest.host }
    public var pages: Int { manifest.items.count }
    public var megabytes: Double { Double(manifest.totalBytes) / 1_048_576 }
    public var costText: String {
        if case .estimated(let s) = manifest.estimatedCost { return s }
        return "未知"
    }
    public var checkboxLabel: String { "我确认将以上 \(pages) 页图片上传到 \(host)" }
}

/// 可替换的后端，单测用假的。
public protocol BookBackend: Sendable {
    func prepare(preset: ProviderPreset, model: String, pdf: URL, forceOCR: Bool, workdir: URL) async throws -> OnlinePlan
    func run(_ o: BookOptions, plan: OnlinePlan?, ticket: UploadTicket?, app: BackendContext) async throws -> BookResult
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

    public func prepare(preset: ProviderPreset, model: String, pdf: URL, forceOCR: Bool, workdir: URL) async throws -> OnlinePlan {
        try await Task.detached { try OnlinePlan.prepare(preset: preset, model: model, pdf: pdf, forceOCR: forceOCR, workdir: workdir, log: { _ in }) }.value
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
    public static let highPrecisionNote = "高精度模式整页读一遍，一本书约 1 小时，需要约 8–10 GB 内存；日常建议关闭。"

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
    @Published public private(set) var isRunning = false
    @Published public private(set) var confirm: ConfirmRequest?
    @Published public private(set) var history: [HistoryRecord]

    private let app: AppModel, backend: BookBackend, modelsDir: URL, store: History
    private var worker: Task<Void, Never>?
    private var cancelFlag = Flag()
    private var batchID = UUID()
    private var answer: CheckedContinuation<(Bool, Scope?), Never>?

    public init(app: AppModel, backend: BookBackend = LocalBackend(), modelsDir: URL = ModelStore.defaultDirectory,
                history: History = History(url: AppPaths.history), outdir: URL) {
        self.app = app; self.backend = backend; self.modelsDir = modelsDir; self.store = history; self.outdir = outdir
        self.history = history.records
    }

    public var vlDirectory: URL { VLModel.directory(models: modelsDir) }
    public var vlInstalled: Bool { FileManager.default.fileExists(atPath: vlDirectory.appendingPathComponent("model.safetensors").path) }
    public var needsVLModel: Bool { highPrecision && !vlInstalled }
    public var coreMLInstalled: Bool { ModelStore.installed(modelsDir) }

    /// 总开关关掉或取消选中后，在线读字自动失效
    public var onlineEnabled: Bool { onlineProviderID.map(app.isUsable) == true && !onlineModel.isEmpty }

    public var blockReason: String? {
        if !makeMarkdown, !makePDF { return "至少选一种产物" }
        if !coreMLInstalled { return "还没有识别模型，请到设置 → 模型下载" }
        if needsVLModel { return "高精度模式需要 VL 模型，请到设置 → 模型下载" }
        if highPrecision, onlineEnabled { return "高精度模式和在线读字只能选一个" }
        if onlineProviderID != nil, !onlineEnabled { return app.networkAllowed ? "在线读字要选中服务商并填模型名" : AppModel.offReason }
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
        if highPrecision { vl = try? await Task.detached { [dir = vlDirectory] in try VLHandle(directory: dir) }.value }
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
                let p = try await backend.prepare(preset: preset, model: onlineModel, pdf: job.pdf, forceOCR: forceOCR, workdir: work)
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
        o.coreml = modelsDir
        let flag = cancelFlag, id = job.id
        o.isCancelled = { flag.value }
        o.progress = { [weak self] stage, done, total in
            Task { @MainActor in self?.set(id, .running(stage: stage.rawValue, done: done, total: total)) }
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

    private func record(_ r: HistoryRecord) {
        store.upsert(r)
        history = store.records
    }

    private func attach(_ r: HistoryRecord, to id: UUID) {
        if let i = jobs.firstIndex(where: { $0.id == id }) { jobs[i].record = r }
    }
}
