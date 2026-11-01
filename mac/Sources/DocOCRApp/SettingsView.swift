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
            DiagnosticsTab().tabItem { Label("诊断", systemImage: "stethoscope") }
        }.padding()
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
                    LabeledContent("状态", value: models.installed(k) ? "已安装" : "未安装")
                    LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: models.sizes[k] ?? 0, countStyle: .file))
                    if let m = models.message[k] { Text(m).foregroundStyle(.secondary) }
                    HStack {
                        Button(models.installed(k) ? "重新下载" : "下载") { models.download(k) }
                        Text(ModelManager.downloadLabel).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("校验") { models.verify(k) }.disabled(!models.installed(k))
                        Button("删除", role: .destructive) { deleting = k }.disabled(!models.installed(k))
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
            Section("服务商（默认一家都不启用，亲自选中才生效）") {
                ForEach(ProviderPresets.all, id: \.id) { p in row(p) }
            }
        }
        .formStyle(.grouped)
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
                HStack {
                    SecureField(providers.hasKey(p.id) ? "Key 已保存在 Keychain" : "API Key", text: Binding(get: { keys[p.id] ?? "" }, set: { keys[p.id] = $0 }))
                    Button("保存") {
                        providers.saveKey(keys[p.id] ?? "", for: p.id)
                        keys[p.id] = ""
                    }
                    Button("删除") { providers.deleteKey(p.id) }.disabled(!providers.hasKey(p.id))
                }
                HStack {
                    TextField("模型名", text: Binding(get: { providers.models[p.id] ?? "" }, set: { providers.models[p.id] = $0 }))
                    Button("测试连接") { providers.test(p) }.disabled(!providers.canTest(p)).help("只发程序生成的合成图")
                }
            }
            if let r = providers.result[p.id] { Text(r).font(.caption) }
        }.disabled(!app.networkControlsEnabled && p.dialect == .openAICompatible && !app.selected.contains(p.id))
    }
}

struct DiagnosticsTab: View {
    @EnvironmentObject var d: DiagnosticsModel

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
