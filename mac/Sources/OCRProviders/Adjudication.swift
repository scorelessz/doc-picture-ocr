#if canImport(CryptoKit)
import Foundation
import OCRCore

// 在线裁决（docs/P6_DESIGN.md 第 7 节）。只传分歧行；答案只有序号，写不进候选之外的字。

public enum AdjudicationMode: String, Sendable {
    case image, text

    public var evidence: String { self == .image ? "image" : "text_only" }
    public var title: String { self == .image ? "看图裁决" : "纯文本裁决（仅文本依据）" }
}

public struct AdjudicationQuestion: Sendable {
    public let id: String, pageIndex: Int, lineIndex: Int, page: Int
    public let candidates: [String]
    public let crop: Data?          // 看图裁决：只有这一行
    public let context: [String]    // 纯文本裁决：前后各一行

    /// 展示顺序。当前读法不能总排第一，否则模型会偏向它。由 id 决定，清单才可复现。
    var order: [Int] {
        let n = candidates.count, shift = id.utf8.reduce(0) { ($0 &* 31 &+ Int($1)) & 0xffff } % max(1, n)
        return (0..<n).map { ($0 + shift) % n }
    }
}

public enum AdjudicationAnswer: Sendable, Equatable {
    case chosen(index: Int)
    case undecided(reason: String)
}

public func adjudicationQuestions(_ doc: FusedDoc, pages: Set<Int>?, mode: AdjudicationMode,
                                  crop: (Int, FusedLine) throws -> Data?) rethrows -> [AdjudicationQuestion] {
    var out: [AdjudicationQuestion] = []
    for (pi, p) in doc.pages.enumerated() where pages?.contains(p.page) ?? true {
        for (li, l) in p.lines.enumerated() where l.flag == "divergent" {
            let c = lineCandidates(l)
            guard c.count >= 2 else { continue }
            let ctx = mode == .text ? [li - 1, li + 1].filter(p.lines.indices.contains).map { p.lines[$0].text } : []
            out.append(AdjudicationQuestion(id: "p\(p.page)-l\(li)", pageIndex: pi, lineIndex: li, page: p.page, candidates: c,
                                            crop: mode == .image ? try crop(p.page, l) : nil, context: ctx))
        }
    }
    return out
}

public enum AdjudicationBody {
    static func prompt(_ q: AdjudicationQuestion) -> String {
        var s = q.crop != nil ? "图中是书页的一行文字。" : "下面是书里一行文字的几种 OCR 读法。"
        if !q.context.isEmpty { s += "\n上下文：\n" + q.context.joined(separator: "\n") }
        s += "\n候选读法：\n"
        for (i, k) in q.order.enumerated() { s += "\(i): \(q.candidates[k])\n" }
        s += "选出正确的一个，只回答 JSON：{\"choice\": 序号}。都不对或判断不了时回答 {\"choice\": null}。"
        return s
    }

    public static func make(model: String, _ q: AdjudicationQuestion) throws -> Data {
        var content: [[String: Any]] = [["type": "text", "text": prompt(q)]]
        if let c = q.crop {
            content.insert(["type": "image_url", "image_url": ["url": "data:image/png;base64,\(c.base64EncodedString())"]], at: 0)
        }
        return try JSONSerialization.data(withJSONObject: ["model": model, "temperature": 0, "max_tokens": 512, "response_format": ["type": "json_object"],
                                                           "messages": [["role": "user", "content": content]]], options: [.sortedKeys])
    }

    /// 只认 {"choice": 合法序号}，序号是展示顺序，换算回候选下标。其余一律 undecided，保留本地读法。
    public static func parse(_ reply: String, order: [Int]) -> AdjudicationAnswer {
        guard let o = (try? JSONSerialization.jsonObject(with: Data(reply.utf8))) as? [String: Any], o.count == 1,
              let c = o["choice"] else { return .undecided(reason: "unparsable") }
        if c is NSNull { return .undecided(reason: "model_undecided") }
        var index: Int?
        if let s = c as? String, s.allSatisfy(\.isNumber) {
            index = Int(s)
        } else if let v = c as? NSNumber, CFGetTypeID(v) != CFBooleanGetTypeID(), v.doubleValue == v.doubleValue.rounded() {
            index = v.intValue
        }
        guard let index, order.indices.contains(index) else { return .undecided(reason: "out_of_range") }
        return .chosen(index: order[index])
    }
}

public struct AdjudicationOutcome: Sendable {
    public var doc: FusedDoc
    public var chosen = 0, changed = 0
    public var undecided: [String: Int] = [:]
    public var stoppedEarly: String?

    public init(doc: FusedDoc) { self.doc = doc }
}

extension AdjudicationOutcome {
    public func summary(provider: String, model: String, mode: AdjudicationMode, total: Int) -> AdjudicationSummary {
        var s = AdjudicationSummary(provider: provider, model: model, mode: mode.title)
        s.total = total
        s.chosen = chosen
        s.changed = changed
        s.failed = (undecided["request_failed"] ?? 0) + (undecided["not_sent"] ?? 0)
        s.undecided = undecided.filter { !["request_failed", "not_sent"].contains($0.key) }.values.reduce(0, +)
        s.stopped = stoppedEarly
        s.rows = doc.pages.flatMap { p in
            p.lines.compactMap { l in
                l.adjudication.flatMap { $0.from == l.text ? nil : AdjudicationSummary.Row(page: p.page, from: $0.from, to: l.text) }
            }
        }
        return s
    }
}

/// 逐条裁决。鉴权之类的硬失败立刻停，其余条目保留本地读法；不换家，不退回别的方式。
public func runAdjudication(_ doc: FusedDoc, questions: [AdjudicationQuestion], pages: [OnlinePage], mode: AdjudicationMode,
                            reader: OnlineReader, providerID: String, model: String) async -> AdjudicationOutcome {
    var o = AdjudicationOutcome(doc: doc)
    let byID = Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
    for (n, q) in questions.enumerated() {
        guard let p = byID[q.id] else { continue }
        do {
            let reply = try await reader.read(p)
            let a = AdjudicationBody.parse(reply, order: q.order)
            var f: [String: LogValue] = ["page": .i(q.page), "item": .s(q.id), "evidence": .s(mode.evidence),
                                         "result": .s({ if case .chosen(let i) = a { return "chosen:\(i)" }; return "undecided" }())]
            if Log.shared.withText { f["reply"] = .s(String(reply.prefix(120))) }
            Log.shared.debug("adjudication", f)
            switch a {
            case .chosen(let i):
                let line = o.doc.pages[q.pageIndex].lines[q.lineIndex]
                o.doc.pages[q.pageIndex].lines[q.lineIndex] = chooseCandidate(line, index: i, adjudication:
                    Adjudication(provider: providerID, model: model, evidence: mode.evidence, from: line.text))
                o.chosen += 1
                if i != 0 { o.changed += 1 }
            case .undecided(let r):
                o.undecided[r, default: 0] += 1
            }
        } catch {
            o.undecided["request_failed", default: 0] += 1
            if case OnlineError.http(let c)? = error as? OnlineError, c == 429 || c >= 500 { continue }
            if error is URLError || error as? OnlineError == .emptyReply { continue }
            o.stoppedEarly = "\(error)"
            o.undecided["not_sent", default: 0] += questions.count - n - 1
            break
        }
    }
    return o
}
#endif
