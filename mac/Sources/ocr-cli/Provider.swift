import Foundation
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
