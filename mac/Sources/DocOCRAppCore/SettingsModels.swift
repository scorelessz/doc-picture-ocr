import Combine
import Foundation
import OCRCore
import OCREngines
import OCRProviders

// 设置页的几块：模型管理、服务商、诊断。

public enum ModelKind: String, CaseIterable, Identifiable, Sendable {
    case coreml, vl

    public var id: String { rawValue }
    public var title: String { self == .coreml ? "识别模型（PP-OCRv6，Core ML）" : "高精度模型（PaddleOCR-VL-1.6 8bit）" }
    public var source: String { self == .coreml ? "GitHub Release \(ModelRelease.version)" : "Hugging Face \(VLModel.repo)@\(VLModel.revision.prefix(12))" }
}

public func directorySize(_ u: URL) -> Int64 {
    guard let e = FileManager.default.enumerator(at: u, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
    var n: Int64 = 0
    for case let f as URL in e {
        n += Int64((try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
    }
    return n
}

@MainActor
public final class ModelManager: ObservableObject {
    public static let downloadLabel = "仅下载模型，不上传文件"

    @Published public private(set) var busy: Set<ModelKind> = []
    @Published public private(set) var message: [ModelKind: String] = [:]
    @Published public private(set) var sizes: [ModelKind: Int64] = [:]
    public let dir: URL, bundled: URL?

    public init(dir: URL = ModelStore.defaultDirectory, bundled: URL? = ModelStore.bundledDirectory) {
        self.dir = dir
        self.bundled = bundled
        refresh()
    }

    /// 识别模型在 App 包里时不能下载、不能删
    public func isBundled(_ k: ModelKind) -> Bool { k == .coreml && bundled != nil }

    private var vl: URL { VLModel.directory(models: dir) }

    public func installed(_ k: ModelKind) -> Bool {
        k == .coreml ? (bundled != nil || ModelStore.installed(dir)) : FileManager.default.fileExists(atPath: vl.appendingPathComponent("model.safetensors").path)
    }

    public func refresh() {
        let (dir, vl, bundled) = (dir, vl, bundled)
        Task.detached {
            let v = directorySize(vl), all = directorySize(bundled ?? dir)
            await MainActor.run { [weak self] in self?.sizes = [.vl: v, .coreml: bundled != nil ? all : max(0, all - v)] }
        }
    }

    private func work(_ k: ModelKind, _ busyText: String, _ f: @escaping @Sendable () throws -> String) {
        guard !busy.contains(k) else { return }
        busy.insert(k)
        message[k] = busyText
        Task.detached {
            let text: String
            do { text = try f() } catch { text = "失败: \(error)" }
            await MainActor.run { [weak self] in
                self?.busy.remove(k)
                self?.message[k] = text
                self?.refresh()
            }
        }
    }

    /// 模型下载单独放行，不受总开关约束（只连白名单地址）
    public func download(_ k: ModelKind) {
        let (dir, vl) = (dir, vl)
        work(k, "下载中…") {
            if k == .coreml {
                try ModelStore.fetch(url: nil, sha: nil, into: dir) { _ in }
            } else {
                try ModelStore.fetchVL(into: vl) { _ in }
            }
            return "下载完成，校验通过"
        }
    }

    /// zip 是识别模型包，文件夹是 VL 模型。不联网，校验不过什么都不装。
    public func importFile(_ u: URL) {
        let (dir, vl) = (dir, vl)
        let folder = (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        work(folder ? .vl : .coreml, "导入中…") {
            if folder {
                try ModelStore.importVL(u, into: vl)
            } else {
                try ModelStore.importZip(u, into: dir)
            }
            return "导入完成，校验通过"
        }
    }

    public func verify(_ k: ModelKind) {
        let (dir, vl, bundled) = (dir, vl, bundled)
        work(k, "校验中…") {
            if k == .vl {
                let bad = VLModel.problems(vl)
                return bad.isEmpty ? "校验通过" : "不符: \(bad)"
            }
            let m = modelManifest(bundled ?? dir)
            return m.isEmpty ? "清单缺失" : "清单完好（\(m.count) 个模型）"
        }
    }

    /// Core ML 和 VL 在同一目录下，删一个不能带上另一个
    public func delete(_ k: ModelKind) {
        let (dir, vl) = (dir, vl)
        work(k, "删除中…") {
            let fm = FileManager.default
            if k == .vl {
                try fm.removeItem(at: vl)
            } else {
                for f in try fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) where f.lastPathComponent != "vl" {
                    try fm.removeItem(at: f)
                }
            }
            return "已删除"
        }
    }
}

@MainActor
public final class ProviderSettings: ObservableObject {
    public static let overwriteNote = "检测到旧条目，将覆盖保存"
    public static let authorizeHint = "系统会弹授权框，请选「始终允许」。没有授权时也可以直接填新 Key 覆盖。"

    @Published public var models: [String: String] = [:]
    @Published public private(set) var result: [String: String] = [:]
    @Published public private(set) var testing: Set<String> = []
    @Published public private(set) var lists: [String: CachedModels] = [:]
    @Published public private(set) var listError: [String: String] = [:]
    @Published public private(set) var loading: Set<String> = []
    @Published public private(set) var profiles: [String: [CapabilityProfile]] = [:]
    private let app: AppModel, store: KVStore, profileDir: URL

    public init(app: AppModel, store: KVStore = DefaultsStore(), profileDir: URL = ProfileStore.defaultDirectory) {
        self.app = app; self.store = store; self.profileDir = profileDir
        for p in ProviderPresets.all {
            models[p.id] = store.string("model." + p.id) ?? p.recommendedVision ?? p.recommendedText ?? ""
            lists[p.id] = ProfileStore.models(p.id, in: profileDir)
            profiles[p.id] = ProfileStore.profiles(p.id, in: profileDir)
        }
    }

    public func jobs(_ id: String) -> Int {
        store.string("jobs." + id).flatMap(Int.init).map(OnlineJobs.clamp) ?? OnlineJobs.default
    }

    public func setJobs(_ n: Int, for id: String) {
        store.set(String(OnlineJobs.clamp(n)), "jobs." + id)
        objectWillChange.send()
    }

    public func setModel(_ m: String, for id: String) {
        models[id] = m
        store.set(m, "model." + id)
    }

    // MARK: Key

    public func keyState(_ id: String) -> KeyState { (try? app.secrets.state(id)) ?? .none }

    public func hasKey(_ id: String) -> Bool {
        if case .readable = keyState(id) { return true }
        return false
    }

    /// 永远不含明文
    public func keyLine(_ id: String) -> String {
        func when(_ d: Date?) -> String { d.map { "，修改于 " + Self.time($0) } ?? "" }
        switch keyState(id) {
        case .none: return "未设置"
        case let .readable(p, n, d): return "已保存（本 App 可读）\(p)…，共 \(n) 位\(when(d))"
        case let .needsAuthorization(d): return "已保存但需授权\(when(d))"
        }
    }

    static func time(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: d)
    }

    public func needsAuthorization(_ id: String) -> Bool {
        if case .needsAuthorization = keyState(id) { return true }
        return false
    }

    public func saveKey(_ key: String, for id: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do {
            let replaced = try app.secrets.save(k, for: id)
            result[id] = replaced ? "已覆盖旧条目，Key 已存入 Keychain" : "Key 已存入 Keychain"
        } catch { result[id] = "保存失败: \(error)" }
        objectWillChange.send()
    }

    public func deleteKey(_ id: String) {
        do {
            try app.secrets.delete(id)
            result[id] = "Key 已删除"
        } catch { result[id] = "\(error)" }
        objectWillChange.send()
    }

    /// 用户点按钮才走这里：会弹系统授权框，放后台，不卡界面
    public func authorize(_ id: String) {
        let s = app.secrets
        result[id] = Self.authorizeHint
        Task.detached {
            let r: String
            do {
                r = try s.loadAuthorizing(id) != nil ? "授权成功" : "没有这个条目"
            } catch { r = "没有授权成功: \(error)" }
            await MainActor.run { [weak self] in
                self?.result[id] = r
                self?.objectWillChange.send()
            }
        }
    }

    // MARK: 模型列表

    public func options(_ p: ProviderPreset) -> [ModelOption] {
        ModelFilter.options(ids: lists[p.id]?.ids ?? [], profiles: profiles[p.id] ?? [], recommended: p.recommendedVision ?? p.recommendedText)
    }

    /// 没联网或没刷新到时显示缓存时间
    public func listNote(_ p: ProviderPreset) -> String? {
        if p.textOnly { return "\(p.name)只用于纯文本裁决，看图不稳定" }
        guard let l = lists[p.id] else { return "还没有拉取过模型列表" }
        return (app.networkAllowed ? "列表更新于 " : "没有联网，这是上次的列表，更新于 ") + Self.time(l.fetchedAt)
    }

    public func canRefresh(_ p: ProviderPreset) -> Bool { refreshBlock(p) == nil }

    /// 为什么现在不能拉列表。nil 表示可以。
    public func refreshBlock(_ p: ProviderPreset) -> String? {
        if !app.networkAllowed { return AppModel.offReason }
        if p.dialect != .openAICompatible { return "这家的适配还没有做" }
        if !app.selected.contains(p.id) { return "还没有选中这家服务商" }
        switch keyState(p.id) {
        case .none: return "还没有填 Key"
        case .needsAuthorization: return "Key 需要先授权或重新保存"
        case .readable: return nil
        }
    }

    /// 只发 GET /models，不发用户数据。条件不满足时一次请求都不发。
    public func refreshModels(_ p: ProviderPreset) async {
        if let why = refreshBlock(p) {
            listError[p.id] = why
            Log.shared.info("provider_models", ["provider": .s(p.id), "ok": .b(false), "reason": .s(why)])
            return
        }
        guard !loading.contains(p.id), let ep = try? Endpoint(p.baseURL) else { return }
        loading.insert(p.id)
        defer { loading.remove(p.id) }
        let prober = CapabilityProber(transport: app.transport, endpoint: ep, providerID: p.id, key: try? app.secrets.load(p.id))
        switch await prober.fetchModels() {
        case .success(let ids) where !ids.isEmpty:
            let c = CachedModels(fetchedAt: Date(), ids: ids)
            try? ProfileStore.saveModels(c, for: p.id, in: profileDir)
            lists[p.id] = c
            listError[p.id] = nil
            Log.shared.info("provider_models", ["provider": .s(p.id), "ok": .b(true), "count": .i(ids.count)])
        case .success:
            fail(p, "服务商返回了空列表")
        case .failure(let e):
            fail(p, "\(e)")
        }
    }

    /// 失败时保留上次的缓存
    private func fail(_ p: ProviderPreset, _ why: String) {
        listError[p.id] = why
        Log.shared.warn("provider_models", ["provider": .s(p.id), "ok": .b(false), "reason": .s(why)])
    }

    /// 只刷新已选中的，没选中的不算失败
    public func refreshAll() async {
        for p in ProviderPresets.all where app.selected.contains(p.id) { await refreshModels(p) }
    }

    public func canTest(_ p: ProviderPreset) -> Bool {
        canRefresh(p) && !(models[p.id] ?? "").isEmpty && !testing.contains(p.id)
    }

    /// 只发合成图。总开关和选中状态由传输层再把一道。
    public func test(_ p: ProviderPreset) {
        guard canTest(p), let model = models[p.id], let ep = try? Endpoint(p.baseURL) else { return }
        testing.insert(p.id)
        result[p.id] = "测试中…（只发程序生成的合成图）"
        Log.shared.info("provider_test_start", ["provider": .s(p.id), "model": .s(model)])
        let prober = CapabilityProber(transport: app.transport, endpoint: ep, providerID: p.id, key: try? app.secrets.load(p.id))
        let dir = profileDir
        Task {
            var text: String
            do {
                let r = try await prober.probe(model: model)
                try? ProfileStore.save(r, in: dir)
                profiles[p.id] = ProfileStore.profiles(p.id, in: dir)
                text = "支持图片: \(r.supportsImage ? "是" : "否")；最大长边: \(r.maxLongEdge.map(String.init) ?? "-")"
            } catch { text = "失败: \(error)" }
            testing.remove(p.id)
            result[p.id] = text
            Log.shared.info("provider_test_end", ["provider": .s(p.id), "result": .s(text)])
        }
    }
}

@MainActor
public final class DiagnosticsModel: ObservableObject {
    public static let textWarning = "打开后日志会写入书的正文。不要把这样的日志发给别人。"
    public static let levels = ["off", "error", "warn", "info", "debug", "trace"]

    @Published public var level = "info" { didSet { apply() } }
    @Published public var logText = false { didSet { apply() } }
    @Published public private(set) var system = systemSummary()
    @Published public private(set) var plan: [(model: String, ane: Int, gpu: Int, cpu: Int)] = []
    @Published public private(set) var checks: [DoctorCheck] = []
    @Published public private(set) var checking = false
    public let logFile: URL, modelsDir: URL

    public init(logFile: URL = AppPaths.log, modelsDir: URL = ModelStore.resolvedDirectory) {
        self.logFile = logFile; self.modelsDir = modelsDir
        apply()
    }

    private func apply() {
        var a = ["--log-level", level, "--log-file", logFile.path]
        if logText { a.append("--log-text") }
        _ = try? Log.shared.configure(a, env: [:])
    }

    public func export(to u: URL) throws {
        try? FileManager.default.removeItem(at: u)
        try FileManager.default.copyItem(at: logFile, to: u)
    }

    public func runChecks() {
        guard !checking else { return }
        checking = true
        let (m, tmp) = (modelsDir, FileManager.default.temporaryDirectory)
        Task.detached {
            let c = runDoctor(models: m, outdir: tmp, vlDirectory: VLModel.directory(models: ModelStore.defaultDirectory)), p = await accelerationPlan(models: m)
            await MainActor.run { [weak self] in
                self?.checks = c
                self?.plan = p
                self?.checking = false
            }
        }
    }
}
