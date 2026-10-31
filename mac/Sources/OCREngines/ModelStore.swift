#if canImport(CryptoKit)
import CryptoKit
import Foundation
import OCRCore

// 模型的存放与下载。App 里打包进 bundle；测试期从 GitHub Release 取。

public enum ModelRelease {
    public static let version = "v1"
    public static let file = "DocOCR-models-v1.zip"
    public static let url = "https://github.com/scorelessz/doc-picture-ocr/releases/download/models-v1/DocOCR-models-v1.zip"
    public static let sha256 = "76d4ad930531344f75ba2293ca999b2ff623242ad713a9691cc5d75c978d9be6"
    public static let size = 138692895
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

    static func sha256(_ url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url)
        defer { try? h.close() }
        var s = SHA256()
        while let d = try h.read(upToCount: 1 << 20), !d.isEmpty { s.update(data: d) }
        return s.finalize().map { String(format: "%02x", $0) }.joined()
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
        if u.isFileURL {
            try fm.copyItem(at: u, to: zip)
        } else {
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
                do { try FileManager.default.moveItem(at: loc, to: zip) } catch { failure = "\(error)" }
            }
            task.resume()
            sem.wait()
            if let failure { throw ModelError.download(failure) }
        }
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
        _ = try? fm.removeItem(at: dir)
        try fm.moveItem(at: root, to: dir)
        Log.shared.info("models_fetched", ["dir": .s(dir.path), "sha256": .s(String(got.prefix(12)))])
    }
}
#endif
