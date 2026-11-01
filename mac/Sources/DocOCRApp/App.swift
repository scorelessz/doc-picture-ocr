import AppKit
import DocOCRAppCore
import OCRCore
import OCREngines
import OCRProviders
import SwiftUI

@MainActor
final class Env: ObservableObject {
    let app: AppModel, queue: QueueModel, models: ModelManager, providers: ProviderSettings, diagnostics: DiagnosticsModel

    init(store: KVStore = DefaultsStore(), secrets: SecretStore = KeychainStore(), outdir: URL? = nil) {
        app = AppModel(store: store, secrets: secrets)
        let out = outdir ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("DocOCR", isDirectory: true)
        queue = QueueModel(app: app, prefs: store, outdir: out)
        models = ModelManager()
        providers = ProviderSettings(app: app, store: store)
        diagnostics = DiagnosticsModel()
        ExitTrace.install()
    }
}

/// 闪退排查：有 app_start 没有 app_exit、也没有崩溃报告，就是被 SIGKILL。SIGTERM、SIGHUP 和未捕获异常都留一行。
enum ExitTrace {
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static func install() {
        let info = Bundle.main.infoDictionary
        Log.shared.info("app_start", ["pid": .i(Int(getpid())), "path": .s(Bundle.main.executablePath ?? "?"),
                                      "version": .s(info?["CFBundleShortVersionString"] as? String ?? "dev"),
                                      "commit": .s(info?["DocOCRGitCommit"] as? String ?? "dev")])
        atexit { Log.shared.info("app_exit", ["pid": .i(Int(getpid()))]) }
        NSSetUncaughtExceptionHandler { e in Log.shared.error("app_exception", ["name": .s(e.name.rawValue), "reason": .s(e.reason ?? "")]) }
        for sig in [SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let s = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            s.setEventHandler {
                Log.shared.warn("app_signal", ["signal": .i(Int(sig))])
                exit(128 + sig)
            }
            s.resume()
            sources.append(s)
        }
    }
}

@main
struct DocOCRApp: App {
    @StateObject private var env = Env()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)     // swift run 启动时没有 bundle，要手动成为前台 App
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
        let a = CommandLine.arguments
        if a.contains("--smoke") || a.contains("--snapshot") || a.contains("--keychain-test") || a.contains("--test-connection") {
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
