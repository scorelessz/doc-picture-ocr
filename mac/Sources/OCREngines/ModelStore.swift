#if canImport(CryptoKit)
import CryptoKit
import Foundation
import OCRCore

// 模型的存放与下载。App 里打包进 bundle；测试期 Core ML 从 GitHub Release 取，VL 从 Hugging Face 取。

public enum ModelRelease {
    public static let version = "v1"
    public static let file = "DocOCR-models-v1.zip"
    public static let url = "https://github.com/scorelessz/doc-picture-ocr/releases/download/models-v1/DocOCR-models-v1.zip"
    public static let sha256 = "76d4ad930531344f75ba2293ca999b2ff623242ad713a9691cc5d75c978d9be6"
    public static let size = 138692895
}

/// PaddleOCR-VL-1.6 8bit。权重不进我们的 Release，从 Hugging Face 公开仓库取，钉死 commit 和每个文件的 sha256。
public struct VLFile: Sendable {
    public let name: String, sha256: String, size: Int

    public init(name: String, sha256: String, size: Int) {
        self.name = name; self.sha256 = sha256; self.size = size
    }
}

public enum VLModel {
    public static let repo = "OpenGryd/PaddleOCR-VL-1.6-MLX-8bit"
    public static let revision = "dba7c66b4614170eeb132bff0abe4b6dd836a504"
    public static let baseURL = "https://huggingface.co/\(repo)/resolve/\(revision)"
    /// OCRVL 实际读的三个文件
    public static let files = [
        VLFile(name: "config.json", sha256: "45b2be187cfff706db3f67e959020f99223a131baceb6af2f9a4c932999d726f", size: 2676),
        VLFile(name: "tokenizer.json", sha256: "c8a215a59183d0d0781adc33bacd3ce6162716f7fd568fb30234a74d69803a7d", size: 11_189_060),
        VLFile(name: "model.safetensors", sha256: "3abce24b6c447cce0e56ae9fd7464d507c4b288080bdc92526a07668c3a0a0e7", size: 1_088_866_630),
    ]

    /// <models>/vl
    public static func directory(models: URL) -> URL { models.appendingPathComponent("vl", isDirectory: true) }

    /// 逐个文件比 sha256。返回不符的文件名，空表示完好。
    public static func problems(_ dir: URL, files: [VLFile] = VLModel.files) -> [String] {
        files.filter { (try? ModelStore.sha256(dir.appendingPathComponent($0.name))) != $0.sha256 }.map(\.name)
    }
}

public enum ModelError: Error, CustomStringConvertible {
    case checksum(want: String, got: String), download(String), unpack(String)

    public var description: String {
        switch self {
        case let .checksum(w, g): return "sha256 不符: 期望 \(w.prefix(12)), 实际 \(g.prefix(12))"
        case .download(let s): return "下载失败: \(s)"
        case .unpack(let s): return "解压失败: \(s)"
        }
    }
}

public enum ModelStore {
    /// ~/Library/Application Support/DocOCR/models
    public static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("DocOCR/models", isDirectory: true)
    }

    public static func installed(_ dir: URL) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent("keys.txt").path)
    }

    public static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var s = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { s.update(data: d) }
        return s.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func download(_ u: URL, to out: URL, log: (String) -> Void) throws {
        let fm = FileManager.default
        if u.isFileURL {
            try fm.copyItem(at: u, to: out)
            return
        }
        log("下载 \(u.absoluteString)")
        let sem = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var failure: String?
        let task = URLSession.shared.downloadTask(with: u) { loc, resp, err in
            defer { sem.signal() }
            if let err { failure = "\(err)"; return }
            guard let loc, (resp as? HTTPURLResponse)?.statusCode == 200 else {
                let c = (resp as? HTTPURLResponse)?.statusCode ?? 0
                failure = c == 404 ? "HTTP 404: 模型包可能还没发布, 用 --url 指定本地包, 或 tools/convert_paddle.py 自己转" : "HTTP \(c)"
                return
            }
            do { try FileManager.default.moveItem(at: loc, to: out) } catch { failure = "\(error)" }
        }
        task.resume()
        sem.wait()
        if let failure { throw ModelError.download(failure) }
    }

    /// 下载 VL 模型到 dir。全部校验过才换进去；不符的文件立刻删掉，已校验的留在暂存目录，重跑不用再下。
    public static func fetchVL(base: String? = nil, files: [VLFile] = VLModel.files, into dir: URL, log: (String) -> Void) throws {
        guard let root = URL(string: base ?? VLModel.baseURL) else { throw ModelError.download("URL 无效") }
        let fm = FileManager.default
        let part = dir.deletingLastPathComponent().appendingPathComponent(".\(dir.lastPathComponent)-partial", isDirectory: true)
        try fm.createDirectory(at: part, withIntermediateDirectories: true)
        for f in files {
            let out = part.appendingPathComponent(f.name)
            if (try? sha256(out)) == f.sha256 {
                log("\(f.name) 已下载")
                continue
            }
            try? fm.removeItem(at: out)
            try download(root.appendingPathComponent(f.name), to: out, log: log)
            let got = try sha256(out)
            if got != f.sha256 {
                try fm.removeItem(at: out)
                Log.shared.error("vl_fetch_rejected", ["file": .s(f.name), "want": .s(String(f.sha256.prefix(12))), "got": .s(String(got.prefix(12)))])
                throw ModelError.checksum(want: f.sha256, got: got)
            }
            log("\(f.name) sha256 \(got.prefix(12)) 校验通过")
        }
        _ = try? fm.removeItem(at: dir)
        try fm.moveItem(at: part, to: dir)
        Log.shared.info("vl_fetched", ["dir": .s(dir.path), "repo": .s(VLModel.repo), "revision": .s(String(VLModel.revision.prefix(12)))])
    }

    /// 下载（或 file:// 本地取）、校验、解压，换到目标目录。校验不过一个字节都不装。
    public static func fetch(url: String?, sha: String?, into dir: URL, log: (String) -> Void) throws {
        let want = sha ?? ModelRelease.sha256
        guard let u = URL(string: url ?? ModelRelease.url) else { throw ModelError.download("URL 无效") }
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("docoocr-models-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        let zip = tmp.appendingPathComponent("models.zip")
        try download(u, to: zip, log: log)
        let got = try sha256(zip)
        if got != want { throw ModelError.checksum(want: want, got: got) }
        log("sha256 \(got.prefix(12)) 校验通过")
        let un = tmp.appendingPathComponent("x")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, un.path]
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw ModelError.unpack("ditto 退出码 \(p.terminationStatus)") }
        let root = fm.fileExists(atPath: un.appendingPathComponent("keys.txt").path) ? un : un.appendingPathComponent("models")
        guard fm.fileExists(atPath: root.appendingPathComponent("keys.txt").path) else { throw ModelError.unpack("包里没有 keys.txt") }
        try fm.createDirectory(at: dir.deletingLastPathComponent(), withIntermediateDirectories: true)
        // VL 模型单独下载，重装 Core ML 模型时要留着
        let staged = dir.deletingLastPathComponent().appendingPathComponent(".\(dir.lastPathComponent)-new-\(ProcessInfo.processInfo.processIdentifier)")
        try fm.moveItem(at: root, to: staged)
        let oldVL = VLModel.directory(models: dir)
        if fm.fileExists(atPath: oldVL.path) { try fm.moveItem(at: oldVL, to: VLModel.directory(models: staged)) }
        _ = try? fm.removeItem(at: dir)
        try fm.moveItem(at: staged, to: dir)
        Log.shared.info("models_fetched", ["dir": .s(dir.path), "sha256": .s(String(got.prefix(12)))])
    }
}
#endif
