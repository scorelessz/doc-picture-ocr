import Foundation
import OCRCore
import OCREngines
import OCRProviders

// provider 子命令。联网默认关：--allow-network 开总开关，点名的服务商才算用户选中。

private func readKeyFromStdin() -> String {
    (readLine(strippingNewline: true) ?? "").trimmingCharacters(in: .whitespaces)
}

private func await_<T: Sendable>(_ f: @escaping @Sendable () async throws -> T) throws -> T {
    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var out: Result<T, Error>!
    Task.detached {
        do { out = .success(try await f()) } catch { out = .failure(error) }
        sem.signal()
    }
    sem.wait()
    return try out.get()
}

private func makeProber(_ p: ProviderPreset, _ args: [String]) throws -> CapabilityProber {
    guard p.dialect == .openAICompatible else { fail("\(p.name) 的适配还没有做", code: 2) }
    let key = args.contains("--key-stdin") ? SecretKey(readKeyFromStdin()) : try KeychainStore().load(p.id)
    guard let key else { fail("没有 \(p.id) 的 Key: 先跑 ocr-cli provider key set \(p.id)", code: 2) }
    let selection = ProviderSelection()
    selection.select(p.id)      // 命令行点名就是用户选中，只在这次运行有效
    let t = GuardedTransport(wire: URLSessionWire(), network: NetworkSwitch(allowed: true), selection: selection, gate: UploadGate())
    return CapabilityProber(transport: t, endpoint: try Endpoint(p.baseURL), providerID: p.id, key: key)
}

/// book 的在线读字。在做任何 OCR 之前走完确认；不确认就退出，一页都不处理。
func prepareOnlineVLM(_ id: String, into o: inout BookOptions, args: [String]) throws {
    guard args.contains("--allow-network") else { fail("联网默认关闭: 在线读字要显式加 --allow-network", code: 2) }
    guard let p = ProviderPresets.find(id), let model = option(args, "--vlm-model") else { fail("--vlm-provider 要配 --vlm-model，服务商见 ocr-cli provider list", code: 2) }
    guard p.dialect == .openAICompatible else { fail("\(p.name) 的适配还没有做", code: 2) }
    let key = args.contains("--key-stdin") ? SecretKey(readKeyFromStdin()) : try KeychainStore().load(p.id)
    guard let key else { fail("没有 \(p.id) 的 Key: 先跑 ocr-cli provider key set \(p.id)", code: 2) }
    let endpoint = try Endpoint(p.baseURL)
    let stem = o.pdf.deletingPathExtension().lastPathComponent
    let dir = o.workdir.appendingPathComponent("\(stem).upload", isDirectory: true)
    let pages = try prepareOnlinePages(pdf: o.pdf, model: model, maxEdge: 1792, forceOCR: o.forceOCR, into: dir, log: warn)
    let m = onlineManifest(pages, providerID: p.id, providerName: p.name, host: endpoint.host, model: model)
    print("""
    将上传页面图片到非本机地址:
      服务商: \(p.name)  域名: \(endpoint.host)  模型: \(model)
      文件: \(o.pdf.lastPathComponent)
      最多 \(pages.count) 页，共 \(String(format: "%.1f", Double(m.totalBytes) / 1_048_576)) MB（有分歧的页才真正发送），请求约 \(m.estimatedRequests) 次，费用未知
      清单 sha256: \(m.sha256)
    """)
    let gate = UploadGate()
    let confirm = option(args, "--confirm-upload")
    func stop(_ msg: String) -> Never {
        try? FileManager.default.removeItem(at: dir)      // 请求体里是页面图片，不留
        fail(msg, code: 3)
    }
    let interactive = isatty(STDIN_FILENO) == 1
    let ticket: UploadTicket
    if let confirm {
        do {
            ticket = try await_ {
                await gate.request(m)
                return try await gate.confirm(manifestSHA256: confirm)
            }
        } catch { stop("清单 sha256 不符，任务不开始") }
    } else if interactive {
        print("确认上传请手动输入完整域名（\(endpoint.host)），其他输入取消: ", terminator: "")
        let ok = readLine(strippingNewline: true) == endpoint.host
        guard ok else { stop("未确认，任务不开始") }
        ticket = try await_ {
            await gate.request(m)
            return try await gate.confirm(checkbox: true, scope: .once)
        }
    } else {
        stop("未确认，任务不开始。非交互运行请加 --confirm-upload <上面的清单 sha256>")
    }
    let selection = ProviderSelection()
    selection.select(p.id)
    let t = GuardedTransport(wire: URLSessionWire(), network: NetworkSwitch(allowed: true), selection: selection, gate: gate)
    let uploads = o.outdir.appendingPathComponent("\(stem).uploads.jsonl")
    try FileManager.default.createDirectory(at: o.outdir, withIntermediateDirectories: true)
    let reader = OnlineReader(transport: t, endpoint: endpoint, providerID: p.id, model: model, key: key, ticket: ticket, ledger: try FileLedger(uploads))
    let byPage = Dictionary(uniqueKeysWithValues: pages.map { ($0.page, $0) })
    o.uploadsPath = uploads
    o.uploadBodies = dir
    o.vlmOnline = { pno in
        guard let page = byPage[pno] else { throw OnlineError.emptyReply }
        return try await_ { try await reader.read(page) }
    }
}

/// adjudicate 子命令：对做完的 fused.json 裁决分歧行。任务就是裁决本身，确认在第一个请求之前。
func runAdjudicate(_ args: [String]) throws {
    guard let path = args.first, let id = option(args, "--provider"), let model = option(args, "--model"), let out = option(args, "--out"),
          let p = ProviderPresets.find(id) else { fail(usage) }
    guard args.contains("--allow-network") else { fail("联网默认关闭: 在线裁决要显式加 --allow-network", code: 2) }
    guard let mode = AdjudicationMode(rawValue: option(args, "--mode") ?? "image") else { fail(usage) }
    guard p.dialect == .openAICompatible else { fail("\(p.name) 的适配还没有做", code: 2) }
    if FileManager.default.fileExists(atPath: out), !args.contains("--force") { fail("\(out) 已存在, 拒绝覆盖（要覆盖请加 --force）") }
    let key = args.contains("--key-stdin") ? SecretKey(readKeyFromStdin()) : try KeychainStore().load(p.id)
    guard let key else { fail("没有 \(p.id) 的 Key: 先跑 ocr-cli provider key set \(p.id)", code: 2) }
    let doc = try JSONDecoder().decode(FusedDoc.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    let pages = option(args, "--pages").map { Set($0.split(separator: ",").compactMap { Int($0) }) }
    if mode == .image, option(args, "--pdf") == nil { fail("--mode image 要配 --pdf", code: 2) }
    let cropper = try option(args, "--pdf").map { try LineCropper(pdf: URL(fileURLWithPath: $0), doc: doc) }
    let qs = try adjudicationQuestions(doc, pages: pages, mode: mode) { pno, l in try cropper?.crop(page: pno, line: l) }
    guard !qs.isEmpty else { fail("没有要裁决的分歧行", code: 2) }
    let endpoint = try Endpoint(p.baseURL)
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dococr-adj-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let source = URL(fileURLWithPath: path).lastPathComponent
    let items = try qs.map { q -> OnlinePage in
        let b = try AdjudicationBody.make(model: model, q), f = dir.appendingPathComponent(q.id + ".json")
        try b.write(to: f)
        return OnlinePage(id: q.id, sourceFile: source, page: q.page, body: f, bytes: b.count)
    }
    let m = onlineManifest(items, providerID: p.id, providerName: p.name, host: endpoint.host, model: model)
    let chars = qs.map { $0.candidates.map(\.count).reduce(0, +) }.reduce(0, +)
    print("""
    将上传分歧行到非本机地址:
      服务商: \(p.name)  域名: \(endpoint.host)  模型: \(model)  方式: \(mode == .image ? "看图" : "仅文本")
      \(qs.count) 处分歧，约 \(chars) 字\(mode == .image ? " / \(qs.count) 张裁切图" : "")，共 \(String(format: "%.2f", Double(m.totalBytes) / 1_048_576)) MB，费用未知
      清单 sha256: \(m.sha256)
    """)
    let gate = UploadGate()
    func stop(_ msg: String) -> Never {
        try? FileManager.default.removeItem(at: dir)
        fail(msg, code: 3)
    }
    let ticket: UploadTicket
    if let confirm = option(args, "--confirm-upload") {
        do {
            ticket = try await_ {
                await gate.request(m)
                return try await gate.confirm(manifestSHA256: confirm)
            }
        } catch { stop("清单 sha256 不符，任务不开始") }
    } else if isatty(STDIN_FILENO) == 1 {
        print("确认上传请手动输入完整域名（\(endpoint.host)），其他输入取消: ", terminator: "")
        guard readLine(strippingNewline: true) == endpoint.host else { stop("未确认，任务不开始") }
        ticket = try await_ {
            await gate.request(m)
            return try await gate.confirm(checkbox: true, scope: .once)
        }
    } else {
        stop("未确认，任务不开始。非交互运行请加 --confirm-upload <上面的清单 sha256>")
    }
    let selection = ProviderSelection()
    selection.select(p.id)
    let t = GuardedTransport(wire: URLSessionWire(), network: NetworkSwitch(allowed: true), selection: selection, gate: gate)
    let reader = OnlineReader(transport: t, endpoint: endpoint, providerID: p.id, model: model, key: key, ticket: ticket,
                              ledger: try FileLedger(URL(fileURLWithPath: out + ".uploads.jsonl")))
    let r = try await_ { await runAdjudication(doc, questions: qs, pages: items, mode: mode, reader: reader, providerID: p.id, model: model) }
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try enc.encode(r.doc).write(to: URL(fileURLWithPath: out))
    print("裁决 \(qs.count) 处: 选定 \(r.chosen), 其中改了读法 \(r.changed), 未决 \(r.undecided)")
    if let s = r.stoppedEarly { warn("⚠ 提前停止，其余保留本地读法: \(s)") }
}

func runProvider(_ args: [String]) throws {
    guard let sub = args.first else { fail(usage) }
    switch sub {
    case "list":
        for p in ProviderPresets.all { print("\(p.id)\t\(p.name)\t\(p.baseURL)") }
        print("（只是可选列表，默认一家都不启用）")

    case "key":
        guard args.count >= 3, let p = ProviderPresets.find(args[2]) else { fail(usage) }
        switch args[1] {
        case "set":
            let k = readKeyFromStdin()
            guard !k.isEmpty else { fail("stdin 没有读到 Key", code: 2) }
            try KeychainStore().save(k, for: p.id)
            print("已存入 Keychain: \(p.id)")
        case "delete":
            try KeychainStore().delete(p.id)
            print("已删除: \(p.id)")
        default: fail(usage)
        }

    case "models":
        guard args.count >= 2, let p = ProviderPresets.find(args[1]) else { fail(usage) }
        guard args.contains("--allow-network") else { fail("联网默认关闭: 要显式加 --allow-network", code: 2) }
        let prober = try makeProber(p, args)
        for m in try await_({ await prober.listModels() }) { print(m) }

    case "probe":
        guard args.count >= 2, let p = ProviderPresets.find(args[1]), let model = option(args, "--model") else { fail(usage) }
        guard args.contains("--allow-network") else { fail("联网默认关闭: 探测要显式加 --allow-network（只发合成图）", code: 2) }
        let prober = try makeProber(p, args)
        let (models, profile) = try await_ { (await prober.listModels(), try await prober.probe(model: model)) }
        try ProfileStore.save(profile)
        print("\(p.id) \(model): 模型列表 \(models.count) 个, 支持图片 \(profile.supportsImage), 最大长边 \(profile.maxLongEdge.map(String.init) ?? "-"), 响应 \(profile.responseFormat.rawValue)")

    default: fail(usage)
    }
}
