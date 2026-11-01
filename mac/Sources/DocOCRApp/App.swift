import AppKit
import DocOCRAppCore
import OCREngines
import OCRProviders
import SwiftUI

@MainActor
final class Env: ObservableObject {
    let app: AppModel, queue: QueueModel, models: ModelManager, providers: ProviderSettings, diagnostics: DiagnosticsModel

    init(store: KVStore = DefaultsStore(), secrets: SecretStore = KeychainStore(), outdir: URL? = nil) {
        app = AppModel(store: store, secrets: secrets)
        let out = outdir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DocOCR", isDirectory: true)
        queue = QueueModel(app: app, outdir: out)
        models = ModelManager()
        providers = ProviderSettings(app: app)
        diagnostics = DiagnosticsModel()
    }
}

@main
struct DocOCRApp: App {
    @StateObject private var env = Env()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)     // swift run 启动时没有 bundle，要手动成为前台 App
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
        let a = CommandLine.arguments
        if a.contains("--smoke") || a.contains("--snapshot") {
            DispatchQueue.main.async { Task { @MainActor in await TestEntry.run(a) } }
        }
    }

    var body: some Scene {
        WindowGroup("DocOCR") {
            ContentView()
                .environmentObject(env)
                .environmentObject(env.app)
                .environmentObject(env.queue)
                .environmentObject(env.models)
                .environmentObject(env.providers)
                .environmentObject(env.diagnostics)
                .frame(minWidth: 860, minHeight: 600)
        }
        Settings {
            SettingsView()
                .environmentObject(env)
                .environmentObject(env.app)
                .environmentObject(env.queue)
                .environmentObject(env.models)
                .environmentObject(env.providers)
                .environmentObject(env.diagnostics)
                .frame(width: 720, height: 560)
        }
    }
}
