import AppKit
import DocOCRAppCore
import OCRCore
import OCRProviders
import SwiftUI
import UniformTypeIdentifiers

enum Pane: Hashable {
    case queue, record(UUID)
}

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var queue: QueueModel
    @State private var pane: Pane? = .queue

    var body: some View {
        NavigationSplitView {
            List(selection: $pane) {
                Label("处理队列", systemImage: "tray.full").tag(Pane.queue)
                Section("结果") {
                    ForEach(queue.history) { r in
                        VStack(alignment: .leading) {
                            Text(URL(fileURLWithPath: r.pdf).lastPathComponent).lineLimit(1)
                            Text(stateText(r.state)).font(.caption).foregroundStyle(.secondary)
                        }.tag(Pane.record(r.id))
                    }
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 240)
        } detail: {
            switch pane ?? .queue {
            case .queue: QueueView()
            case .record(let id):
                if let r = queue.history.first(where: { $0.id == id }) { ResultView(record: r) } else { QueueView() }
            }
        }
        .onAppear {
            // 测启动时间：窗口出现时写时间戳后退出
            if let i = CommandLine.arguments.firstIndex(of: "--startup-file") {
                try? String(Date().timeIntervalSince1970).write(toFile: CommandLine.arguments[i + 1], atomically: true, encoding: .utf8)
                NSApplication.shared.terminate(nil)
            }
        }
        .sheet(isPresented: .constant(!app.onboardingDone)) {
            OnboardingView().interactiveDismissDisabled()
        }
        .sheet(isPresented: .constant(queue.confirm != nil)) {
            if let c = queue.confirm { ConfirmView(request: c).interactiveDismissDisabled() }
        }
    }
}

func stateText(_ s: String) -> String {
    ["running": "处理中", "done": "完成", "failed": "失败", "cancelled": "已取消", "interrupted": "上次中断"][s] ?? s
}

struct OnboardingView: View {
    @EnvironmentObject var app: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("使用前请先看这段").font(.title2).bold()
            Text(AppModel.warning).foregroundStyle(.red).font(.title3)
            Text("「允许联网」只是解锁设置项，不会启用任何服务商。每次真正上传前还会逐次确认。模型下载只下载、不上传文件，不受这里影响。")
                .foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("我了解风险，允许联网功能") { app.allowNetwork() }
                Button("仅本地使用（推荐）") { app.chooseLocalOnly() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

struct ConfirmView: View {
    let request: ConfirmRequest
    @EnvironmentObject var queue: QueueModel
    @State private var ticked = false
    @State private var forBatch = false

    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).textSelection(.enabled)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("确认上传").font(.title2).bold()
            Text("下面的内容会离开这台 Mac。").foregroundStyle(.red)
            Grid(alignment: .leading, verticalSpacing: 6) {
                row("服务商", request.providerName)
                row("域名", request.host)
                row("文件", request.fileName)
                row(request.contentLabel, request.contentText)
                row("大小", String(format: "%.1f MB", request.megabytes))
                row("请求数", "约 \(request.manifest.estimatedRequests) 次")
                row("预估费用", request.costText)
            }
            Picker("范围", selection: $forBatch) {
                Text("仅本次").tag(false)
                Text("本批次内不再询问").tag(true)
            }.pickerStyle(.radioGroup)
            Toggle(request.checkboxLabel, isOn: $ticked)
            HStack {
                Spacer()
                Button(request.cancelTitle) { queue.declineUpload() }.keyboardShortcut(.cancelAction)
                Button("开始") { queue.confirmUpload(checkbox: ticked, forBatch: forBatch) }.disabled(!ticked)
            }
        }
        .padding(24)
        .frame(width: 520)
    }
}

/// 模型名可以手填，也可以点按钮打开列表搜索。搜索词单独一个框：拿模型名去筛，列表就只剩它自己。
struct ModelField: View {
    let preset: ProviderPreset
    @Binding var text: String
    @EnvironmentObject var providers: ProviderSettings
    @State private var open = false
    @State private var query = ""

    var body: some View {
        HStack(spacing: 4) {
            TextField("模型名", text: $text).frame(minWidth: 200)
            Button { open = true } label: { Image(systemName: "list.bullet") }
                .help("从模型列表选")
                .popover(isPresented: $open, arrowEdge: .bottom) { panel }
        }
    }

    private var panel: some View {
        let all = providers.options(preset), hit = ModelFilter.search(all, query)
        return VStack(alignment: .leading, spacing: 6) {
            TextField("搜索模型", text: $query).textFieldStyle(.roundedBorder)
            HStack {
                Text(query.isEmpty ? "共 \(all.count) 个" : "匹配 \(hit.count) / \(all.count) 个").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button(providers.loading.contains(preset.id) ? "加载中…" : "重新加载") { Task { await providers.refreshModels(preset) } }
                    .disabled(providers.loading.contains(preset.id))
            }
            if let e = providers.listError[preset.id] { Text(e).font(.caption).foregroundStyle(.orange) }
            List(hit) { o in
                Button {
                    text = o.id
                    open = false
                } label: {
                    HStack {
                        Text(o.id).lineLimit(1)
                        Spacer()
                        Text(o.status.rawValue).font(.caption).foregroundStyle(o.status == .unverified ? .secondary : (o.status == .unsupported ? Color.orange : Color.green))
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain)
            }
            if let n = providers.listNote(preset) { Text(n).font(.caption).foregroundStyle(.secondary) }
        }
        .padding(10)
        .frame(width: 420, height: 420)
    }
}

struct QueueView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var providers: ProviderSettings
    @EnvironmentObject var queue: QueueModel
    @State private var targeted = false

    private func pick() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf]
        p.allowsMultipleSelection = true
        if p.runModal() == .OK { queue.add(p.urls) }
    }

    private func pickOutdir() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.canCreateDirectories = true
        if p.runModal() == .OK, let u = p.url { queue.outdir = u }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            dropZone
            if !queue.jobs.isEmpty { jobsList }
            options
            footer
        }
        .padding()
        .navigationTitle("处理队列")
    }

    private var dropZone: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5]))
            .foregroundStyle(targeted ? Color.accentColor : .secondary)
            .frame(height: 76)
            .overlay {
                HStack {
                    Text("把 PDF 拖到这里，或")
                    Button("选择文件…", action: pick)
                }
            }
            .onDrop(of: [.fileURL], isTargeted: $targeted) { items in
                for i in items {
                    _ = i.loadObject(ofClass: URL.self) { u, _ in
                        if let u { Task { @MainActor in queue.add([u]) } }
                    }
                }
                return true
            }
    }

    private var jobsList: some View {
        List(queue.jobs) { j in
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(j.pdf.lastPathComponent).lineLimit(1)
                    JobStatusView(status: j.status)
                }
                Spacer()
                if let o = j.record?.outputs.first {
                    Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: o)]) }
                }
                if !queue.isRunning { Button { queue.remove(j.id) } label: { Image(systemName: "xmark") }.buttonStyle(.borderless) }
            }
        }
        .frame(minHeight: 120)
    }

    private var options: some View {
        GroupBox("选项") {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Toggle("可搜索 PDF", isOn: $queue.makePDF)
                    Toggle("Markdown", isOn: $queue.makeMarkdown)
                    Picker("分页标记", selection: $queue.pageMarks) {
                        Text("无").tag("none")
                        Text("注释").tag("comment")
                        Text("分隔线").tag("rule")
                    }.frame(width: 180).disabled(!queue.makeMarkdown)
                    Spacer()
                }
                HStack {
                    Text("页范围").foregroundStyle(.secondary)
                    TextField("留空为全部，例如 1-20 或 3,5,8", text: $queue.pagesText).frame(width: 260)
                }
                HStack {
                    Text("输出目录").foregroundStyle(.secondary)
                    Text(queue.outdir.path).lineLimit(1).truncationMode(.middle)
                    Button("更改…", action: pickOutdir)
                    Spacer()
                    Toggle("覆盖已有产物", isOn: $queue.overwrite)
                }
                Toggle("忽略已有文字层，重新 OCR", isOn: $queue.forceOCR).help("扫描件自带的文字层往往是别的 OCR 做的，质量差时打开")
                Toggle("高精度模式", isOn: $queue.highPrecision)
                Text(QueueModel.highPrecisionNote).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if queue.highPrecision {
                    Picker("大模型来源", selection: $queue.useLocalService) {
                        Text("进程内（默认）").tag(false)
                        Text("本机服务").tag(true)
                    }.pickerStyle(.segmented).frame(width: 300)
                    if queue.useLocalService { Text("本机服务在设置 → 服务商里配置，仅本机。").font(.caption).foregroundStyle(.secondary) }
                    if queue.needsVLModel {
                        SettingsLink { Text("高精度模型还没装，去模型管理") }
                    }
                }
                onlineOptions
                adjudicationOptions
            }.padding(4)
        }.disabled(queue.isRunning)
    }

    private var onlineOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Picker("在线读字", selection: $queue.onlineProviderID) {
                    Text("不使用").tag(String?.none)
                    ForEach(app.readableProviders, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                }.frame(width: 260)
                if let p = queue.onlineProviderID.flatMap(ProviderPresets.find) {
                    ModelField(preset: p, text: Binding(get: { queue.onlineModel }, set: {
                        queue.onlineModel = $0
                        providers.setModel($0, for: p.id)
                    }))
                }
            }.disabled(!app.networkControlsEnabled)
            if let r = app.networkDisabledReason { Text(r).font(.caption).foregroundStyle(.secondary) }
        }
        .onChange(of: queue.onlineProviderID) { _, id in
            if let id { queue.onlineModel = providers.models[id] ?? "" }
        }
    }

    private var adjudicationOptions: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("在线裁决分歧行", isOn: $queue.adjudicateOn).disabled(!app.networkControlsEnabled)
            if let r = app.networkDisabledReason {
                Text(r).font(.caption).foregroundStyle(.secondary)
            } else if queue.adjudicateOn {
                Picker("方式", selection: $queue.adjudicateMode) {
                    Text("看图裁决").tag(AdjudicationMode.image)
                    Text("纯文本裁决").tag(AdjudicationMode.text)
                }.pickerStyle(.segmented).frame(width: 260)
                Text(queue.adjudicateMode == .image ? "上传分歧行的裁切图和候选文字。" : "只上传候选文字和前后各一行，不传图片，结果标「仅文本依据」。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack {
                    Picker("服务商", selection: $queue.adjudicateProviderID) {
                        Text("请选择").tag(String?.none)
                        ForEach(queue.adjudicateProviders, id: \.id) { Text($0.name).tag(String?.some($0.id)) }
                    }.frame(width: 240)
                    if let p = queue.adjudicateProviderID.flatMap(ProviderPresets.find) {
                        ModelField(preset: p, text: Binding(get: { queue.adjudicateModel }, set: {
                            queue.adjudicateModel = $0
                            providers.setModel($0, for: p.id)
                        }))
                    }
                }
                if queue.adjudicateProviders.isEmpty {
                    Text("没有可用的服务商：请在设置里选中并填好 Key。").font(.caption).foregroundStyle(.orange)
                }
            }
        }
        .onChange(of: queue.adjudicateProviderID) { _, id in
            if let id { queue.adjudicateModel = providers.models[id] ?? "" }
        }
        .onChange(of: queue.adjudicateMode) { _, _ in
            if !queue.adjudicateProviders.contains(where: { $0.id == queue.adjudicateProviderID }) { queue.adjudicateProviderID = nil }
        }
    }

    private var footer: some View {
        HStack {
            if let r = queue.blockReason {
                Text(r).foregroundStyle(.orange)
                if !queue.coreMLInstalled { SettingsLink { Text("去模型管理") } }
            }
            Spacer()
            if queue.isRunning {
                Button("取消", role: .cancel) { queue.cancel() }
            } else {
                Button("开始") { queue.start() }.keyboardShortcut(.defaultAction).disabled(!queue.canStart)
            }
        }
    }
}

struct JobStatusView: View {
    let status: JobStatus

    var body: some View {
        switch status {
        case .queued: Text("排队中").font(.caption).foregroundStyle(.secondary)
        case .preparing: Text("准备上传内容…").font(.caption)
        case .awaitingConfirm: Text("等待确认上传").font(.caption).foregroundStyle(.orange)
        case let .running(stage, done, total):
            VStack(alignment: .leading, spacing: 2) {
                Text(total > 0 ? "\(stage) \(done)/\(total) 页" : stage).font(.caption)
                if total > 0 { ProgressView(value: Double(done), total: Double(total)).frame(width: 240) }
            }
        case .done: Text("完成").font(.caption).foregroundStyle(.green)
        case .failed(let e): Text("失败: \(e)").font(.caption).foregroundStyle(.red).lineLimit(3)
        case .cancelled: Text("已取消").font(.caption).foregroundStyle(.secondary)
        case .declined: Text("未确认上传，任务没有开始").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct ResultView: View {
    let record: HistoryRecord
    @State var sections: [ReportSection] = []
    @State var expanded: Set<Int> = [0, 1, 2]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(URL(fileURLWithPath: record.pdf).lastPathComponent).font(.title2).bold()
                    Text(stateText(record.state)).foregroundStyle(.secondary)
                    Spacer()
                    if let o = record.outputs.first {
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting(record.outputs.map { URL(fileURLWithPath: $0) }) }
                            .help(o)
                    }
                }
                if !record.degraded.isEmpty {
                    GroupBox("降级与问题") {
                        VStack(alignment: .leading) { ForEach(record.degraded, id: \.self) { Text("• " + $0) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else if record.state == "done" {
                    Label("没有降级", systemImage: "checkmark.circle").foregroundStyle(.green)
                }
                if let a = record.adjudication { AdjudicationBox(a: a) }
                if sections.isEmpty {
                    Text(record.outputs.isEmpty ? "没有产物。" : "这份没有报告。已写出的产物: \(record.outputs.count) 个").foregroundStyle(.secondary)
                }
                ForEach(sections) { s in
                    DisclosureGroup(s.title, isExpanded: Binding(get: { expanded.contains(s.id) }, set: { if $0 { expanded.insert(s.id) } else { expanded.remove(s.id) } })) {
                        VStack(alignment: .leading, spacing: 6) { ForEach(Array(s.blocks.enumerated()), id: \.offset) { ReportBlockView(block: $0.element) } }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 4)
                    }
                }
            }.padding()
        }
        .task(id: record.id) {
            let path = record.report
            sections = await Task.detached {
                guard let path, let t = try? String(contentsOfFile: path, encoding: .utf8) else { return [ReportSection]() }
                return ReportDocument.sections(ReportDocument.parse(t))
            }.value
        }
    }
}

struct AdjudicationBox: View {
    let a: AdjudicationSummary

    var body: some View {
        GroupBox("在线裁决") {
            VStack(alignment: .leading, spacing: 3) {
                Text("来源：\(a.provider) / \(a.model)，\(a.mode)")
                if a.declined {
                    Text("\(a.total) 处分歧，你没有确认上传，保留本地结果。")
                } else {
                    Text("共 \(a.total) 处：裁决了 \(a.chosen) 处，改了 \(a.changed) 处，模型判断不了 \(a.undecided) 处，失败 \(a.failed) 处。")
                }
                if let s = a.stopped { Text("提前停止：\(s)").foregroundStyle(.orange) }
                Text("逐条明细见下面的质量报告。").font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ReportBlockView: View {
    let block: ReportBlock

    private func md(_ s: String) -> Text { Text((try? AttributedString(markdown: s)) ?? AttributedString(s)) }

    var body: some View {
        switch block {
        case let .heading(_, t): Text(t).font(.headline)
        case let .bullet(t): md("• " + t).textSelection(.enabled)
        case let .quote(t): md(t).font(.caption).foregroundStyle(.secondary)
        case let .paragraph(t): md(t).textSelection(.enabled)
        case let .table(h, rows):
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 3) {
                GridRow { ForEach(Array(h.enumerated()), id: \.offset) { Text($0.element).bold() } }
                Divider()
                ForEach(Array(rows.prefix(200).enumerated()), id: \.offset) { _, r in
                    GridRow { ForEach(Array(r.enumerated()), id: \.offset) { md($0.element).textSelection(.enabled).lineLimit(4) } }
                }
            }
            if rows.count > 200 { Text("只显示前 200 行，共 \(rows.count) 行，完整内容见报告文件").font(.caption).foregroundStyle(.secondary) }
        }
    }
}
