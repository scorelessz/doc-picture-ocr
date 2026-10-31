// RecognizeDocumentsRequest 调研探针: 对给定页图输出段落/标题/表格/列表与逐行框。文字只进 work/, 不提交。
//   swiftc -O -parse-as-library bench/diag_documents.swift -o work/bench/p4/diag-docs && work/bench/p4/diag-docs out.json a.png b.png
import Foundation
import Vision

func rect(_ r: NormalizedRegion) -> [Double] {
    let b = r.boundingBox.cgRect
    return [b.minX, b.minY, b.width, b.height]    // 归一化, 原点左下
}

@main
struct Probe {
    static func main() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        var out: [[String: Any]] = []
        for path in args.dropFirst() {
            var req = RecognizeDocumentsRequest()
            req.textRecognitionOptions.recognitionLanguages = [Locale.Language(identifier: "zh-Hans"), Locale.Language(identifier: "en-US")]
            req.textRecognitionOptions.useLanguageCorrection = true
            let t0 = Date()
            let obs = try await req.perform(on: URL(fileURLWithPath: path))
            var row: [String: Any] = ["png": path, "seconds": Date().timeIntervalSince(t0), "observations": obs.count]
            if let doc = obs.first?.document {
                row["title"] = doc.title?.transcript as Any
                row["transcript"] = doc.text.transcript
                row["tables"] = doc.tables.count
                row["lists"] = doc.lists.count
                row["list_items"] = doc.lists.map { $0.items.map(\.itemString) }
                row["paragraphs"] = doc.paragraphs.map { p -> [String: Any] in
                    ["text": p.transcript, "box": rect(p.boundingRegion), "lines": p.lines.count,
                     "align": p.textAlignment.map { "\($0)" } ?? "nil"]
                }
            }
            out.append(row)
        }
        let data = try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: args[0]))
    }
}
