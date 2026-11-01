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
    public let dir: URL

    public init(dir: URL = ModelStore.defaultDirectory) {
        self.dir = dir
        refresh()
    }

    private var vl: URL { VLModel.directory(models: dir) }

    public func installed(_ k: ModelKind) -> Bool {
        k == .coreml ? ModelStore.installed(dir) : FileManager.default.fileExists(atPath: vl.appendingPathComponent("model.safetensors").path)
    }

    public func refresh() {
        let (dir, vl) = (dir, vl)
        Task.detached {
            let v = directorySize(vl), all = directorySize(dir)
            await MainActor.run { [weak self] in self?.sizes = [.vl: v, .coreml: max(0, all - v)] }
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

    public func verify(_ k: ModelKind) {
        let (dir, vl) = (dir, vl)
        work(k, "校验中…") {
            if k == .vl {
                let bad = VLModel.problems(vl)
                return bad.isEmpty ? "校验通过" : "不符: \(bad)"
            }
            return modelManifest(dir).isEmpty ? "清单缺失" : "清单完好（\(modelManifest(dir).count) 个模型）"
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
    @Published public var models: [String: String] = [:]
    @Published public private(set) var result: [String: String] = [:]
    @Published public private(set) var testing: Set<String> = []
    private let app: AppModel

    public init(app: AppModel) { self.app = app }

    public func hasKey(_ id: String) -> Bool { (try? app.secrets.load(id)) != nil }

    public func saveKey(_ key: String, for id: String) {
        let k = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !k.isEmpty else { return }
        do {
            try app.secrets.save(k, for: id)
            result[id] = "Key 已存入 Keychain"
        } catch { result[id] = "保存失败: \(error)" }
        objectWillChange.send()
    }

    public func deleteKey(_ id: String) {
        try? app.secrets.delete(id)
        result[id] = "Key 已删除"
        objectWillChange.send()
    }

    public func canTest(_ p: ProviderPreset) -> Bool {
        app.canUse(p) && app.selected.contains(p.id) && hasKey(p.id) && !(models[p.id] ?? "").isEmpty && !testing.contains(p.id)
    }

    /// 只发合成图。总开关和选中状态由传输层再把一道。
    public func test(_ p: ProviderPreset) {
        guard canTest(p), let model = models[p.id], let ep = try? Endpoint(p.baseURL) else { return }
        testing.insert(p.id)
        result[p.id] = "测试中…（只发程序生成的合成图）"
        let prober = CapabilityProber(transport: app.transport, endpoint: ep, providerID: p.id, key: try? app.secrets.load(p.id))
        Task {
            var text: String
            do {
                let n = await prober.listModels().count, r = try await prober.probe(model: model)
                try? ProfileStore.save(r)
                text = "模型列表 \(n) 个；支持图片: \(r.supportsImage ? "是" : "否")；最大长边: \(r.maxLongEdge.map(String.init) ?? "-")"
            } catch { text = "失败: \(error)" }
            testing.remove(p.id)
            result[p.id] = text
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

    public init(logFile: URL = AppPaths.log, modelsDir: URL = ModelStore.defaultDirectory) {
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
            let c = runDoctor(models: m, outdir: tmp), p = await accelerationPlan(models: m)
            await MainActor.run { [weak self] in
                self?.checks = c
                self?.plan = p
                self?.checking = false
            }
        }
    }
}
