import Combine
import Foundation
import OCRCore
import OCREngines
import OCRProviders

// App 的全局状态：首次启动、联网总开关、服务商选中。总开关状态可以落盘，上传确认不落盘。

public protocol KVStore: AnyObject {
    func string(_ k: String) -> String?
    func set(_ v: String?, _ k: String)
}

public final class DefaultsStore: KVStore {
    private let d: UserDefaults

    public init(_ d: UserDefaults = .standard) { self.d = d }

    public func string(_ k: String) -> String? { d.string(forKey: k) }
    public func set(_ v: String?, _ k: String) { d.set(v, forKey: k) }
}

public enum AppPaths {
    public static var support: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DocOCR", isDirectory: true)
    }
    public static var history: URL { support.appendingPathComponent("history.json") }
    public static var log: URL { support.appendingPathComponent("logs/app.log") }
}

@MainActor
public final class AppModel: ObservableObject {
    public static let warning = "开启联网功能后，你选中的页面图片或文字片段会被上传到你选择的服务商。默认不开启，不开启时所有处理都只在本机完成。"
    public static let offReason = "联网功能已关闭：所有处理都只在本机完成。要使用请先开启联网。"

    @Published public private(set) var onboardingDone: Bool
    @Published public private(set) var networkAllowed: Bool
    @Published public private(set) var selected: Set<String>

    public let network: NetworkSwitch, selection: ProviderSelection, gate: UploadGate
    public let transport: GuardedTransport, secrets: SecretStore
    private let store: KVStore

    public init(store: KVStore = DefaultsStore(), wire: WireClient = URLSessionWire(), secrets: SecretStore) {
        self.store = store
        self.secrets = secrets
        let allowed = store.string("networkAllowed") == "1"
        let ids = Set((store.string("selectedProviders") ?? "").split(separator: ",").map(String.init))
        let sw = NetworkSwitch(allowed: allowed), sel = ProviderSelection(), g = UploadGate()
        for id in ids { sel.select(id) }
        onboardingDone = store.string("onboardingDone") == "1"
        networkAllowed = allowed
        selected = ids
        network = sw
        selection = sel
        gate = g
        transport = GuardedTransport(wire: wire, network: sw, selection: sel, gate: g)
    }

    public var networkControlsEnabled: Bool { networkAllowed }
    public var networkDisabledReason: String? { networkAllowed ? nil : Self.offReason }

    public func chooseLocalOnly() {
        finishOnboarding()
        setNetwork(false)
    }

    /// 只是解锁选项，不启用任何服务商
    public func allowNetwork() {
        finishOnboarding()
        setNetwork(true)
    }

    public func turnOffNetwork() { setNetwork(false) }

    private func finishOnboarding() {
        onboardingDone = true
        store.set("1", "onboardingDone")
    }

    private func setNetwork(_ on: Bool) {
        networkAllowed = on
        store.set(on ? "1" : "0", "networkAllowed")
        network.set(allowed: on)
    }

    public func canUse(_ p: ProviderPreset) -> Bool { networkAllowed && p.dialect == .openAICompatible }

    public func unavailableReason(_ p: ProviderPreset) -> String? {
        if !networkAllowed { return Self.offReason }
        return p.dialect == .openAICompatible ? nil : "这家的适配还没有做"
    }

    public func setSelected(_ p: ProviderPreset, _ on: Bool) {
        guard canUse(p) || !on else { return }
        if on {
            selected.insert(p.id)
            selection.select(p.id)
        } else {
            selected.remove(p.id)
            selection.deselect(p.id)
        }
        store.set(selected.sorted().joined(separator: ","), "selectedProviders")
    }

    /// 在线读字能选的：DeepSeek 这类只做纯文本的不列
    public var readableProviders: [ProviderPreset] { ProviderPresets.all.filter { isUsable($0.id) && !$0.textOnly } }

    /// 在线裁决能选的：亲自选中、有可读的 Key。看图裁决不列只做纯文本的服务商。
    public func adjudicationProviders(_ mode: AdjudicationMode) -> [ProviderPreset] {
        ProviderPresets.all.filter { p in
            guard isUsable(p.id), mode == .text || !p.textOnly, case .readable? = try? secrets.state(p.id) else { return false }
            return true
        }
    }

    public func isUsable(_ id: String) -> Bool { networkAllowed && selected.contains(id) && ProviderPresets.find(id).map(canUse) == true }
}
