import AppKit
import DocOCRAppCore
import OCRProviders
import SwiftUI

// 测试入口，脚本用：
//   --smoke <outdir> a.pdf b.pdf [--cancel-after 秒] [--pages 范围] [--keep-pages] [--adjudicate 服务商 模型 image|text [--stub-wire]]   用和界面相同的 QueueModel 跑完，写 smoke.json 后退出
//   --test-connection <服务商> <结果文件>
//   --keychain-test write|read|state|overwrite|delete <结果文件>
//   --snapshot <dir>               把各界面渲染成 PNG 后退出

/// 假线路：不出网，裁决永远回答 1 号。验证真实 runBook 的裁决流程用。
final class StubWire: WireClient, @unchecked Sendable {
    func perform(_ r: URLRequest) async throws -> HTTPReply {
        HTTPReply(status: 200, body: try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": "{\"choice\": 1}"]]]]))
    }

    func cancelAll() {}
}

final class MemoryStore: KVStore {
    private var d: [String: String] = [:]
    func string(_ k: String) -> String? { d[k] }
    func set(_ v: String?, _ k: String) { d[k] = v }
}

@MainActor
enum TestEntry {
    static func run(_ a: [String]) async {
        if let i = a.firstIndex(of: "--test-connection"), i + 2 < a.count {
            await testConnection(a[i + 1], out: URL(fileURLWithPath: a[i + 2]))
        } else if let i = a.firstIndex(of: "--keychain-test"), i + 2 < a.count {
            keychain(a[i + 1], out: URL(fileURLWithPath: a[i + 2]))
        } else if let i = a.firstIndex(of: "--smoke"), i + 1 < a.count {
            await smoke(out: URL(fileURLWithPath: a[i + 1]), pdfs: a[(i + 2)...].filter { $0.hasSuffix(".pdf") }.map { URL(fileURLWithPath: $0) })
        } else if let i = a.firstIndex(of: "--snapshot"), i + 1 < a.count {
            await snapshot(URL(fileURLWithPath: a[i + 1]))
        }
        exit(0)
    }

    /// 单独的 service，不碰用户的条目。结果写文件，打包后 stdout 看不到。
    private static func keychain(_ op: String, out: URL) {
        let k = KeychainStore(service: "com.dococr.keychain-test"), id = "smoke"
        var r: String
        do {
            switch op {
            case "write":
                try k.save("value-1", for: id)
                r = "写入成功"
            case "read":
                r = try k.load(id) != nil ? "读到" : "没有条目"
            case "state":
                switch try k.state(id) {
                case .none: r = "未设置"
                case .readable: r = "可读"
                case .needsAuthorization: r = "需授权"
                }
            case "overwrite":
                let had = try k.save("value-2", for: id)
                r = "覆盖成功 旧条目=\(had), " + (try k.load(id) != nil ? "读到" : "没有条目")
            default:
                try k.delete(id)
                r = "已删除"
            }
        } catch { r = "错误: \(error)" }
        try? r.write(to: out, atomically: true, encoding: .utf8)
    }

    /// 走和「测试连接」按钮相同的 ProviderSettings.test，只发合成图。Key 从 stdin 读，只放内存。
    private static func testConnection(_ id: String, out: URL) async {
        guard let p = ProviderPresets.find(id), let key = readLine() else { return }
        let s = MemorySecretStore()
        try? s.save(key, for: id)
        let store = MemoryStore(), dir = out.deletingLastPathComponent().appendingPathComponent("prof")
        let app = AppModel(store: store, secrets: s)
        app.allowNetwork()
        app.setSelected(p, true)
        let m = ProviderSettings(app: app, store: store, profileDir: dir)
        await m.refreshModels(p)
        m.test(p)
        while m.testing.contains(id) { try? await Task.sleep(nanoseconds: 50_000_000) }
        try? (m.result[id] ?? "无结果").write(to: out, atomically: true, encoding: .utf8)
    }

    private static func smoke(out: URL, pdfs: [URL]) async {
        let secrets = MemorySecretStore(), args = CommandLine.arguments
        let stub = args.contains("--stub-wire")
        let app = stub ? AppModel(store: MemoryStore(), wire: StubWire(), secrets: secrets) : AppModel(store: MemoryStore(), secrets: secrets)
        let q = QueueModel(app: app, history: History(url: out.appendingPathComponent("history.json")), prefs: MemoryStore(), outdir: out)
        q.overwrite = true
        if let i = args.firstIndex(of: "--pages") { q.pagesText = args[i + 1] }
        q.keepPages = args.contains("--keep-pages")
        // --adjudicate <服务商> <模型> <image|text>：Key 从 stdin 读，确认窗自动确认
        if let i = args.firstIndex(of: "--adjudicate"), let p = ProviderPresets.find(args[i + 1]), let key = stub ? "stub" : readLine() {
            try? secrets.save(key, for: p.id)
            app.allowNetwork()
            app.setSelected(p, true)
            q.adjudicateOn = true
            q.adjudicateProviderID = p.id
            q.adjudicateModel = args[i + 2]
            q.adjudicateMode = AdjudicationMode(rawValue: args[i + 3]) ?? .image
            Task { @MainActor in
                while !Task.isCancelled {
                    if q.confirm != nil { q.confirmUpload(checkbox: true, forBatch: false) }
                    try? await Task.sleep(nanoseconds: 100_000_000)
                }
            }
        }
        q.forceOCR = true
        q.highPrecision = CommandLine.arguments.contains("--high-precision")
        q.add(pdfs)
        let cancelAfter = CommandLine.arguments.firstIndex(of: "--cancel-after").map { Double(CommandLine.arguments[$0 + 1]) ?? 0 }
        var maxGap = 0.0
        let beat = Task { @MainActor in
            var last = Date()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 20_000_000)
                maxGap = max(maxGap, Date().timeIntervalSince(last) - 0.02)
                last = Date()
            }
        }
        let t0 = Date()
        var cancelSeconds = 0.0
        q.start()
        if let cancelAfter {
            try? await Task.sleep(nanoseconds: UInt64(cancelAfter * 1e9))
            let tc = Date()
            q.cancel()
            await q.waitUntilIdle()
            cancelSeconds = Date().timeIntervalSince(tc)
        }
        await q.waitUntilIdle()
        beat.cancel()
        let rows = q.jobs.map { j -> [String: Any] in
            ["seconds": Date().timeIntervalSince(t0), "main_thread_max_gap": maxGap, "cancel_seconds": cancelSeconds, "pdf": j.pdf.lastPathComponent, "status": "\(j.status)", "pages": j.record?.pages ?? 0, "sec_per_page": j.record?.secPerPage ?? 0,
             "outputs": j.record?.outputs.count ?? 0, "degraded": j.record?.degraded ?? [],
             "adjudication": j.record?.adjudication.map { "总 \($0.total) 裁决 \($0.chosen) 改 \($0.changed) 判断不了 \($0.undecided) 失败 \($0.failed)" } ?? ""]
        }
        let d = try? JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
        try? d?.write(to: out.appendingPathComponent("smoke.json"))
    }

    private static func render<V: View>(_ v: V, _ size: CGSize, _ url: URL) {
        let h = NSHostingView(rootView: v.frame(width: size.width, height: size.height).background(Color(nsColor: .windowBackgroundColor)))
        h.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: h.frame, styleMask: [.titled], backing: .buffered, defer: false)
        w.contentView = h
        h.layoutSubtreeIfNeeded()
        guard let rep = h.bitmapImageRepForCachingDisplay(in: h.bounds) else { return }
        h.cacheDisplay(in: h.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func snapshot(_ dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let env = Env(store: MemoryStore(), secrets: MemorySecretStore(), outdir: dir)
        env.app.chooseLocalOnly()
        env.queue.add([URL(fileURLWithPath: "/tmp/示例.pdf")])
        func wrap<V: View>(_ v: V) -> some View {
            v.environmentObject(env).environmentObject(env.app).environmentObject(env.queue).environmentObject(env.models)
                .environmentObject(env.providers).environmentObject(env.diagnostics)
        }
        render(wrap(OnboardingView()), CGSize(width: 520, height: 240), dir.appendingPathComponent("onboarding.png"))
        render(wrap(QueueView()), CGSize(width: 760, height: 560), dir.appendingPathComponent("queue-offline.png"))
        env.queue.adjudicateOn = true
        render(wrap(QueueView()), CGSize(width: 620, height: 450), dir.appendingPathComponent("queue-small.png"))
        render(wrap(ContentView()), CGSize(width: 860, height: 600), dir.appendingPathComponent("content-min.png"))
        env.queue.adjudicateOn = false
        render(wrap(ProvidersTab()), CGSize(width: 700, height: 520), dir.appendingPathComponent("providers-offline.png"))
        render(wrap(ModelsTab()), CGSize(width: 700, height: 520), dir.appendingPathComponent("models.png"))
        render(wrap(DiagnosticsTab()), CGSize(width: 700, height: 520), dir.appendingPathComponent("diagnostics.png"))
        let m = UploadManifest(providerID: "dashscope", providerName: "阿里云百炼", host: "dashscope.aliyuncs.com", model: "m",
                               items: [UploadItem(id: "p1", sourceFile: "示例.pdf", page: 1, bytes: 750_000)], estimatedRequests: 1)
        render(wrap(ConfirmView(request: ConfirmRequest(manifest: m, fileName: "示例.pdf"))), CGSize(width: 520, height: 380), dir.appendingPathComponent("confirm.png"))
        if let i = CommandLine.arguments.firstIndex(of: "--report"), let t = try? String(contentsOfFile: CommandLine.arguments[i + 1], encoding: .utf8) {
            var r = HistoryRecord(pdf: "/tmp/示例.pdf", outdir: dir.path, startedAt: Date(), state: "done")
            r.outputs = [CommandLine.arguments[i + 1]]
            render(wrap(ResultView(record: r, sections: ReportDocument.sections(ReportDocument.parse(t)))), CGSize(width: 760, height: 900), dir.appendingPathComponent("result.png"))
        }
    }
}
