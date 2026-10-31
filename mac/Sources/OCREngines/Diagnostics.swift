#if canImport(PDFKit)
import CoreML
import CoreGraphics
import CoreText
import Foundation
import OCRCore
import PDFKit
import Vision

// 诊断日志的环境头、内存采样、ocr-cli doctor。

private func sysctl(_ k: String) -> String? {
    var n = 0
    guard sysctlbyname(k, nil, &n, nil, 0) == 0, n > 0 else { return nil }
    var b = [CChar](repeating: 0, count: n)
    guard sysctlbyname(k, &b, &n, nil, 0) == 0 else { return nil }
    return String(cString: b)
}

private func sysctl64(_ k: String) -> Int {
    var v: Int64 = 0, n = MemoryLayout<Int64>.size
    return sysctlbyname(k, &v, &n, nil, 0) == 0 ? Int(v) : 0
}

public func peakRSSMB() -> (own: Double, children: Double) {
    func q(_ who: Int32) -> Double {
        var u = rusage()
        getrusage(who, &u)
        return (Double(u.ru_maxrss) / 1_048_576 * 10).rounded() / 10
    }
    return (q(RUSAGE_SELF), q(RUSAGE_CHILDREN))
}

/// 源码 commit：可执行文件在 <repo>/.build/release/ 下时读得到；否则 unknown。
func gitCommit() -> String {
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
    var dir = exe.deletingLastPathComponent()
    for _ in 0..<5 {
        let head = dir.appendingPathComponent(".git/HEAD")
        if let h = try? String(contentsOf: head, encoding: .utf8) {
            let t = h.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.hasPrefix("ref: ") {
                let r = dir.appendingPathComponent(".git/" + t.dropFirst(5))
                if let v = try? String(contentsOf: r, encoding: .utf8) { return String(v.prefix(12)) }
                return "packed:" + t.dropFirst(5)
            }
            return String(t.prefix(12))
        }
        dir.deleteLastPathComponent()
    }
    return "unknown"
}

func freeDiskGB(_ path: String) -> Double {
    let u = URL(fileURLWithPath: path)
    let v = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    return ((Double(v?.volumeAvailableCapacityForImportantUsage ?? 0) / 1_073_741_824) * 10).rounded() / 10
}

public func modelManifest(_ dir: URL?) -> [String: LogValue] {
    guard let dir, let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
          let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          let m = o["models"] as? [String: [String: Any]] else { return [:] }
    return m.mapValues { .s(String(($0["sha256"] as? String ?? "?").prefix(12))) }
}

public func logEnvironment(args: [String], models: URL? = nil) {
    guard Log.shared.enabled else { return }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    Log.shared.info("env", [
        "macos": .s("\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"),
        "chip": .s(sysctl("machdep.cpu.brand_string") ?? "?"),
        "ram_gb": .d((Double(sysctl64("hw.memsize")) / 1_073_741_824 * 10).rounded() / 10),
        "cpus": .i(ProcessInfo.processInfo.activeProcessorCount),
        "disk_free_gb": .d(freeDiskGB(FileManager.default.currentDirectoryPath)),
        "commit": .s(gitCommit()),
        "vision_text_revision": .i(VNRecognizeTextRequestRevision3),
        "models": .o(modelManifest(models)),
        "argv": .a(args.map { .s($0) }),
    ])
}

/// 模型实际落点：MLComputePlan 的算子分布。
public func logComputePlan(_ engine: PaddleEngine, units: MLComputeUnits, label: String) {
    guard Log.shared.enabled, #available(macOS 14.4, *), let items = try? engine.allCompiled() else { return }
    let sem = DispatchSemaphore(value: 0)
    Task {
        for (name, url) in items {
            if let p = try? await computePlan(url, name: name, units: units, label: label) {
                Log.shared.info("compute_plan", ["model": .s(p.model), "requested": .s(label), "ops": .i(p.ops),
                                                 "ane": .i(p.ane), "gpu": .i(p.gpu), "cpu": .i(p.cpu)])
            }
        }
        sem.signal()
    }
    sem.wait()
}

// MARK: - doctor

public struct DoctorCheck: Encodable, Sendable {
    public let name: String
    public let ok: Bool
    public let detail: String
    public var required = true
}

/// 画一行字给 Vision 读，确认文字识别可用。
private func sampleImage() -> CGImage? {
    let w = 640, h = 80
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(gray: 0, alpha: 1)
    let attr = NSAttributedString(string: "doctor 123", attributes: [
        kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 48, nil),
        kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true])
    let line = CTLineCreateWithAttributedString(attr)
    ctx.textPosition = CGPoint(x: 20, y: 20)
    CTLineDraw(line, ctx)
    return ctx.makeImage()
}

public func runDoctor(models: URL, outdir: URL) -> [DoctorCheck] {
    var r: [DoctorCheck] = []
    func add(_ n: String, _ ok: Bool, _ d: String, required: Bool = true) {
        r.append(DoctorCheck(name: n, ok: ok, detail: d, required: required))
        Log.shared.info("doctor", ["check": .s(n), "ok": .b(ok), "detail": .s(d)])
    }
    let os = ProcessInfo.processInfo.operatingSystemVersion
    add("macos", os.majorVersion >= 14, "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)，要求 14+")
    add("disk", freeDiskGB(FileManager.default.currentDirectoryPath) > 2, "可用 \(freeDiskGB(FileManager.default.currentDirectoryPath)) GB")

    if let img = sampleImage(), let lines = try? VisionEngine.recognize(img) {
        let t = lines.map(\.text).joined()
        add("vision", t.lowercased().contains("doctor"), "读出 \(lines.count) 行")
    } else {
        add("vision", false, "Vision 调用失败")
    }

    let doc = PDFDocument()
    add("pdfkit", doc.pageCount == 0, "PDFDocument 可用")

    let tmp = outdir.appendingPathComponent(".doctor-\(ProcessInfo.processInfo.processIdentifier)")
    do {
        try FileManager.default.createDirectory(at: outdir, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: tmp)
        try FileManager.default.removeItem(at: tmp)
        add("write", true, outdir.path)
    } catch {
        add("write", false, "\(outdir.path): \(error)")
    }

    guard FileManager.default.fileExists(atPath: models.appendingPathComponent("keys.txt").path) else {
        add("models", false, "\(models.path) 没有模型（先跑 ocr-cli models fetch）")
        return r
    }
    let manifest = modelManifest(models)
    add("models", !manifest.isEmpty, "\(models.path): \(manifest.count) 个模型")
    for (label, u) in [("ane", MLComputeUnits.cpuAndNeuralEngine), ("all", .all), ("cpu", .cpuOnly)] {
        do {
            let e = try PaddleEngine(directory: models, units: u)
            guard let img = sampleImageForPage() else { continue }
            let t0 = Date()
            let lines = try e.recognize(img)
            add("coreml_\(label)", lines.contains { $0.text.lowercased().contains("doctor") },
                String(format: "读出 %d 行, %.2fs（含编译载入）", lines.count, Date().timeIntervalSince(t0)), required: label == "cpu")
            if label == "ane" { logComputePlan(e, units: u, label: label) }
        } catch {
            add("coreml_\(label)", false, "\(error)", required: label == "cpu")
        }
    }
    return r
}

/// 一页大小的样张（走检测模型的固定尺寸）。
private func sampleImageForPage() -> CGImage? {
    let w = 1240, h = 2026
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
    ctx.setFillColor(gray: 1, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.setFillColor(gray: 0, alpha: 1)
    let attr = NSAttributedString(string: "doctor self check 123", attributes: [
        kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, 60, nil),
        kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true])
    ctx.textPosition = CGPoint(x: 100, y: 1000)
    CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
    return ctx.makeImage()
}
#endif
