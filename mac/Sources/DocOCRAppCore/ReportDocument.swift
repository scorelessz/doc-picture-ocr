import Foundation

// 把 report.md 解析成结构，界面直接渲染。报告内容只有 OCRCore 的 buildReport 一个来源，这里不重新计算任何数字。

public enum ReportBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case table(header: [String], rows: [[String]])
    case bullet(String), quote(String), paragraph(String)
}

public struct ReportSection: Identifiable, Equatable, Sendable {
    public let id: Int, title: String, blocks: [ReportBlock]
}

public enum ReportDocument {
    public static func parse(_ md: String) -> [ReportBlock] {
        var out: [ReportBlock] = []
        var rows: [[String]] = []
        func flush() {
            guard let h = rows.first else { return }
            out.append(.table(header: h, rows: Array(rows.dropFirst())))
            rows = []
        }
        for raw in md.components(separatedBy: "\n") {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("|") {
                let c = l.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast().map { $0.trimmingCharacters(in: .whitespaces) }
                if !c.allSatisfy({ $0.allSatisfy { "-: ".contains($0) } && !$0.isEmpty }) { rows.append(c) }
                continue
            }
            flush()
            if l.isEmpty { continue }
            if l.hasPrefix("#") {
                let n = l.prefix { $0 == "#" }.count
                out.append(.heading(level: n, text: l.dropFirst(n).trimmingCharacters(in: .whitespaces)))
            } else if l.hasPrefix("- ") {
                out.append(.bullet(String(l.dropFirst(2))))
            } else if l.hasPrefix(">") {
                out.append(.quote(l.dropFirst().trimmingCharacters(in: .whitespaces)))
            } else {
                out.append(.paragraph(l))
            }
        }
        flush()
        return out
    }

    /// 按二级标题分节
    public static func sections(_ blocks: [ReportBlock]) -> [ReportSection] {
        var out: [ReportSection] = [], title = "概览", cur: [ReportBlock] = []
        for b in blocks {
            if case .heading(2, let t) = b {
                if !cur.isEmpty { out.append(ReportSection(id: out.count, title: title, blocks: cur)) }
                title = t
                cur = []
            } else {
                cur.append(b)
            }
        }
        if !cur.isEmpty { out.append(ReportSection(id: out.count, title: title, blocks: cur)) }
        return out
    }
}
