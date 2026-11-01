import AppKit
import DocOCRAppCore
import OCRProviders
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    var body: some View {
        TabView {
            ModelsTab().tabItem { Label("模型", systemImage: "shippingbox") }
            ProvidersTab().tabItem { Label("服务商", systemImage: "network") }
            AdvancedTab().tabItem { Label("高级", systemImage: "slider.horizontal.3") }
            DiagnosticsTab().tabItem { Label("诊断", systemImage: "stethoscope") }
        }.padding()
    }
}

struct AdvancedTab: View {
    @EnvironmentObject var queue: QueueModel

    var body: some View {
        Form {
            Section("计算单元") {
                Picker("Core ML", selection: $queue.unitsLabel) {
                    Text("ANE（默认）").tag("ane")
                    Text("全部").tag("all")
                    Text("GPU").tag("gpu")
                    Text("CPU").tag("cpu")
                }
                Text("遇到兼容问题时切换。").font(.caption).foregroundStyle(.secondary)
            }
            Section("高精度模式") {
                Toggle("对所有页调用大模型", isOn: $queue.vlmAll)
                Text("默认只读有分歧的页。实测两本书都只多 2 页。").font(.caption).foregroundStyle(.secondary)
                Toggle("段落切分听大模型（实验）", isOn: $queue.vlmBreaks)
                Text("实测没有改善，中文不加保护时还会错并段落。").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }
}

struct ModelsTab: View {
    @EnvironmentObject var models: ModelManager
    @State private var deleting: ModelKind?

    var body: some View {
        Form {
            ForEach(ModelKind.allCases) { k in
                Section(k.title) {
                    LabeledContent("来源", value: k.source)
                    LabeledContent("状态", value: models.isBundled(k) ? "已内置在 App 里" : (models.installed(k) ? "已安装" : "未安装"))
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: models.sizes[k] ?? 0, countStyle: .file))
                    if let m = models.message[k] { Text(m).foregroundStyle(.secondary) }
                    HStack {
                        if !models.isBundled(k) {
                            Button(models.installed(k) ? "重新下载" : "下载") { models.download(k) }
                            Text(ModelManager.downloadLabel).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("校验") { models.verify(k) }.disabled(!models.installed(k))
                        if !models.isBundled(k) {
                            Button("删除", role: .destructive) { deleting = k }.disabled(!models.installed(k))
                        }
                    }.disabled(models.busy.contains(k))
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("确定删除这个模型？删除后要重新下载。", isPresented: .constant(deleting != nil)) {
            Button("删除", role: .destructive) {
                if let k = deleting { models.delete(k) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        }
    }
}

struct ProvidersTab: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var providers: ProviderSettings
    @State private var keys: [String: String] = [:]
    @State private var confirmingOn = false
    @FocusState private var focused: String?

    var body: some View {
        Form {
            Section("联网总开关") {
                if app.networkAllowed {
                    Text("联网功能已开启。每次上传前仍会逐次确认。")
                    Button("关闭联网") { app.turnOffNetwork() }
                } else {
                    Text(AppModel.offReason).foregroundStyle(.secondary)
                    Button("去开启…") { confirmingOn = true }
                }
            }
            LocalServiceSection()
            Section("服务商（默认一家都不启用，亲自选中才生效）") {
                ForEach(ProviderPresets.all, id: \.id) { p in row(p) }
            }
        }
        .formStyle(.grouped)
        .task(id: app.networkAllowed) { await providers.refreshAll() }
        .alert("开启联网功能", isPresented: $confirmingOn) {
            Button("仅本地使用", role: .cancel) {}
            Button("我了解风险，允许联网功能") { app.allowNetwork() }
        } message: { Text(AppModel.warning) }
    }

    @ViewBuilder private func row(_ p: ProviderPreset) -> some View {
        let on = Binding(get: { app.selected.contains(p.id) }, set: { app.setSelected(p, $0) })
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: on) {
                VStack(alignment: .leading) {
                    Text(p.name)
                    Text(p.baseURL).font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(!app.canUse(p))
            if let r = app.unavailableReason(p) { Text(r).font(.caption).foregroundStyle(.secondary) }
            if app.selected.contains(p.id) {
                Text("Key: " + providers.keyLine(p.id)).font(.caption)
                if providers.needsAuthorization(p.id) {
                    HStack {
                        Text("这个 Key 是别的构建存的。").font(.caption).foregroundStyle(.orange)
                        Button("授权读取旧 key") { providers.authorize(p.id) }.help(ProviderSettings.authorizeHint)
                        Button("覆盖为新 key") { focused = p.id }
                    }
                    if !(keys[p.id] ?? "").isEmpty { Text(ProviderSettings.overwriteNote).font(.caption).foregroundStyle(.orange) }
                }
                HStack {
                    SecureField("API Key", text: Binding(get: { keys[p.id] ?? "" }, set: { keys[p.id] = $0 })).focused($focused, equals: p.id)
                    Button("保存") {
                        providers.saveKey(keys[p.id] ?? "", for: p.id)
                        keys[p.id] = ""
                        Task { await providers.refreshModels(p) }
                    }
                    Button("删除") { providers.deleteKey(p.id) }.disabled(providers.keyState(p.id) == .none)
                }
                Stepper("并发数：\(providers.jobs(p.id))", value: Binding(get: { providers.jobs(p.id) }, set: { providers.setJobs($0, for: p.id) }), in: OnlineJobs.range)
                    .help("同时发几个请求。设成 1 就是逐个发。被限流时会自动降低，不会换服务商。")
                if !p.textOnly {
                    HStack {
                        ModelField(preset: p, text: Binding(get: { providers.models[p.id] ?? "" }, set: { providers.setModel($0, for: p.id) }))
                        Button("测试连接") { providers.test(p) }.disabled(!providers.canTest(p)).help("只发程序生成的合成图")
                    }
                }
                if let n = providers.listNote(p) { Text(n).font(.caption).foregroundStyle(.secondary) }
                if let e = providers.listError[p.id] {
                    HStack {
                        Text("模型列表没有加载成功：\(e)").font(.caption).foregroundStyle(.orange)
                        Button("重新加载") { Task { await providers.refreshModels(p) } }.disabled(providers.loading.contains(p.id))
                    }
                }
            }
            if let r = providers.result[p.id] { Text(r).font(.caption) }
        }.disabled(!app.networkControlsEnabled && p.dialect == .openAICompatible && !app.selected.contains(p.id))
    }
}

/// Ollama、LM Studio、mlx-vlm 这类本机服务：不算联网，不受总开关限制，不走上传确认
struct LocalServiceSection: View {
    @EnvironmentObject var queue: QueueModel

    var body: some View {
        Section("本机服务（仅本机）") {
            TextField("地址", text: $queue.localURL, prompt: Text("http://127.0.0.1:11434/v1"))
            TextField("模型名", text: $queue.localModel)
            HStack {
                Button("Ollama") { queue.localURL = "http://127.0.0.1:11434/v1" }
                Button("LM Studio") { queue.localURL = "http://127.0.0.1:1234/v1" }
                Button("mlx-vlm") { queue.localURL = "http://127.0.0.1:8080/v1" }
            }
            if !queue.localURL.isEmpty, queue.localEndpoint == nil {
                Text("只接受本机地址。").foregroundStyle(.orange)
            }
            Text("只连这台 Mac 上的服务，文件不离开本机。在高精度模式里选「本机服务」后使用。").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct DiagnosticsTab: View {
    @EnvironmentObject var d: DiagnosticsModel
    @EnvironmentObject var queue: QueueModel

    private func export() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "DocOCR.log"
        if p.runModal() == .OK, let u = p.url { try? d.export(to: u) }
    }

    var body: some View {
        Form {
            Section("日志") {
                Picker("级别", selection: $d.level) { ForEach(DiagnosticsModel.levels, id: \.self) { Text($0) } }
                Toggle("日志包含正文", isOn: $d.logText)
                if d.logText { Text(DiagnosticsModel.textWarning).foregroundStyle(.red) }
                Button("导出日志…", action: export)
            }
            Section("中间文件") {
                Toggle("保留中间页图", isOn: $queue.keepPages)
                Text("每页一张图，整本要占几 GB 磁盘，处理完需要手动清理。").font(.caption).foregroundStyle(.secondary)
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([queue.pageDirectory]) }
            }
            Section("这台 Mac") {
                LabeledContent("芯片", value: d.system.chip)
                LabeledContent("内存", value: "\(d.system.ramGB) GB")
                LabeledContent("macOS", value: d.system.macOS)
            }
            Section("环境自检与加速落点") {
                Button(d.checking ? "检查中…" : "运行自检", action: d.runChecks).disabled(d.checking)
                ForEach(d.checks, id: \.name) { c in
                    Text("\(c.ok ? "✓" : (c.required ? "✗" : "△")) \(c.name): \(c.detail)").font(.caption).lineLimit(2)
                }
                ForEach(d.plan, id: \.model) { p in
                    Text("\(p.model): ANE \(p.ane) / GPU \(p.gpu) / CPU \(p.cpu)").font(.caption)
                }
            }
        }.formStyle(.grouped)
    }
}
