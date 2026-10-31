import Foundation

// bin/vision-ocr 的 TSV 行格式：x  y  w  h  confidence  text（像素，原点左上）。
// Phase 2 的对拍门槛就是逐行比这个格式，所以格式化必须与 src/vision_ocr.swift 完全一致。

public func tsvLine(_ l: Line) -> String {
    let text = l.text.replacingOccurrences(of: "\t", with: " ")
    return String(format: "%.1f\t%.1f\t%.1f\t%.1f\t%.4f\t", l.x, l.y, l.w, l.h, l.conf) + text
}

public func parseTSV(_ s: String) -> [Line] {
    s.split(separator: "\n", omittingEmptySubsequences: true).compactMap { row in
        let c = row.split(separator: "\t", maxSplits: 5, omittingEmptySubsequences: false)
        guard c.count == 6, let x = Double(c[0]), let y = Double(c[1]), let w = Double(c[2]),
              let h = Double(c[3]), let conf = Double(c[4]),
              !c[5].trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return Line(x: x, y: y, w: w, h: h, conf: conf, text: String(c[5]))
    }
}
