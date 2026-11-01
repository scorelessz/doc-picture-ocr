#if canImport(CryptoKit)
import Foundation
import OCRCore
import XCTest
@testable import OCRProviders

private func line(_ t: String, alt: String? = nil, flag: String = "") -> FusedLine {
    FusedLine(x: 100, y: 200, w: 300, h: 40, text: t, conf: 1, src: "both", alt: alt, flag: flag)
}

private func doc(_ lines: [FusedLine], page: Int = 1) throws -> FusedDoc {
    let lj = try JSONEncoder().encode(lines)
    let stats = "{\"pages\":1,\"lines\":0,\"both\":0,\"divergent\":0,\"only_vision\":0,\"only_rapidocr\":0,\"low_conf\":0,\"glossary_hits\":0,\"dropped_empty\":0,\"dropped_contained\":0}"
    let j = "{\"source\":\"a.pdf\",\"engines\":[\"vision\",\"rapidocr\"],\"stats\":\(stats),\"dpi\":300,\"pages\":[{\"page\":\(page),\"width\":1000,\"height\":1600,\"pdf_width\":500,\"pdf_height\":800,\"zoom\":2,\"rotation\":0,\"native_text\":false,\"lines\":\(String(decoding: lj, as: UTF8.self))}]}"
    return try JSONDecoder().decode(FusedDoc.self, from: Data(j.utf8))
}

private func reply(_ t: String) -> HTTPReply {
    HTTPReply(status: 200, body: try! JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": t]]]]))
}

final class AdjudicationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("adj-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testParseOnlyAcceptsValidIndex() {              // 27, 28
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": 1}", order: [0, 1]), .chosen(index: 1))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": 2}", order: [0, 1]), .undecided(reason: "out_of_range"))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": -1}", order: [0, 1]), .undecided(reason: "out_of_range"))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": 0.5}", order: [0, 1]), .undecided(reason: "out_of_range"))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": true}", order: [0, 1]), .undecided(reason: "out_of_range"))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": \"1\"}", order: [0, 1]), .chosen(index: 1))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": \"新字\"}", order: [0, 1]), .undecided(reason: "out_of_range"))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": 0}", order: [1, 0]), .chosen(index: 1))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": null}", order: [0, 1]), .undecided(reason: "model_undecided"))
        XCTAssertEqual(AdjudicationBody.parse("正确的是: 模型自己写的新字", order: [0, 1]), .undecided(reason: "unparsable"))
        XCTAssertEqual(AdjudicationBody.parse("{\"choice\": 1, \"text\": \"新字\"}", order: [0, 1]), .undecided(reason: "unparsable"))
    }

    func testAdjudicationSurvivesEncoding() throws {
        var l = line("b")
        l.adjudication = Adjudication(provider: "p", model: "m", evidence: "image", from: "c")
        XCTAssertEqual(try JSONDecoder().decode(FusedLine.self, from: try JSONEncoder().encode(l)).adjudication, l.adjudication)
    }

    func testOrderIsStableAndNotAlwaysCurrentFirst() {
        func q(_ id: String) -> AdjudicationQuestion {
            AdjudicationQuestion(id: id, pageIndex: 0, lineIndex: 0, page: 1, candidates: ["a", "b"], crop: nil, context: [])
        }
        XCTAssertEqual(q("p1-l3").order, q("p1-l3").order)
        XCTAssertEqual(Set((0..<20).map { q("p1-l\($0)").order[0] }), [0, 1])
    }

    func testOnlyDivergentLinesBecomeQuestions() throws {   // 29
        let d = try doc([line("a"), line("b", alt: "c", flag: "divergent"), line("d", alt: "e", flag: "low_conf")])
        let q = adjudicationQuestions(d, pages: nil, mode: .text) { _, _ in nil }
        XCTAssertEqual(q.map(\.candidates), [["b", "c"]])
        XCTAssertEqual(q[0].context, ["a", "d"])
    }

    func testPageFilter() throws {
        let d = try doc([line("b", alt: "c", flag: "divergent")], page: 7)
        XCTAssertTrue(adjudicationQuestions(d, pages: [1], mode: .text) { _, _ in nil }.isEmpty)
    }

    func testCropRectStaysNearLine() {                   // 30
        let r = lineCropRect(line("x"), imageWidth: 1000, imageHeight: 1600)
        XCTAssertEqual(r.h, 40 + 20)
        XCTAssertLessThanOrEqual(r.w, 300 + 20)
        let edge = lineCropRect(FusedLine(x: -5, y: 1590, w: 2000, h: 40, text: "", conf: 1, src: "", alt: nil, flag: ""), imageWidth: 1000, imageHeight: 1600)
        XCTAssertEqual(edge.x, 0)
        XCTAssertLessThanOrEqual(edge.y + edge.h, 1600)
    }

    func testTextModeBodyHasNoImage() throws {           // 31
        let d = try doc([line("b", alt: "c", flag: "divergent")])
        let q = adjudicationQuestions(d, pages: nil, mode: .text) { _, _ in XCTFail("文本模式不该裁图"); return nil }
        let s = String(decoding: try AdjudicationBody.make(model: "m", q[0]), as: UTF8.self)
        XCTAssertFalse(s.contains("image_url"))
    }

    func testCandidateChoiceKeepsOthersAsAlt() {
        let a = Adjudication(provider: "p", model: "m", evidence: "text_only", from: "b")
        let out = chooseCandidate(line("b", alt: "c ‖ d", flag: "divergent"), index: 2, adjudication: a)
        XCTAssertEqual(out.text, "d")
        XCTAssertEqual(out.alt, "b ‖ c")
        XCTAssertEqual(out.adjudication, a)
        XCTAssertEqual(chooseCandidate(line("b", alt: "c"), index: 9, adjudication: a).text, "b")
    }

    /// 让第一条选到「非当前读法」的展示序号
    private func flipIndex(_ d: FusedDoc) throws -> Int {
        adjudicationQuestions(d, pages: nil, mode: .text) { _, _ in nil }[0].order.firstIndex(of: 1)!
    }

    private func setup(_ d: FusedDoc, mode: AdjudicationMode, replies: [HTTPReply]) async throws -> ([AdjudicationQuestion], [OnlinePage], OnlineReader, MockWire) {
        let q = adjudicationQuestions(d, pages: nil, mode: mode) { _, _ in Data([1]) }
        let pages = try q.map { x -> OnlinePage in
            let b = try AdjudicationBody.make(model: "m", x), f = dir.appendingPathComponent(x.id)
            try b.write(to: f)
            return OnlinePage(id: x.id, sourceFile: "a.pdf", page: x.page, body: f, bytes: b.count)
        }
        let w = MockWire(replies), s = ProviderSelection(), g = UploadGate()
        s.select("p")
        let t = GuardedTransport(wire: w, network: NetworkSwitch(allowed: true), selection: s, gate: g)
        await g.request(onlineManifest(pages, providerID: "p", providerName: "P", host: "api.example.com", model: "m"))
        let tk = try await g.confirm(checkbox: true, scope: .once)
        let r = OnlineReader(transport: t, endpoint: try Endpoint("https://api.example.com/v1"), providerID: "p", model: "m", key: nil,
                             ticket: tk, ledger: MemoryLedger(), backoff: { _ in })
        return (q, pages, r, w)
    }

    func testRunMarksEvidenceAndKeepsBodyOnBadReply() async throws {   // 28, 32
        let d = try doc([line("b", alt: "c", flag: "divergent"), line("x", alt: "y", flag: "divergent")])
        let (q, p, r, _) = try await setup(d, mode: .text, replies: [reply("{\"choice\": \(try flipIndex(d))}"), reply("润色后的新文字")])
        let o = await runAdjudication(d, questions: q, pages: p, mode: .text, reader: r, providerID: "p", model: "m")
        XCTAssertEqual(o.doc.pages[0].lines[0].text, "c")
        XCTAssertEqual(o.doc.pages[0].lines[0].adjudication?.evidence, "text_only")
        XCTAssertEqual(o.doc.pages[0].lines[1].text, "x")
        XCTAssertEqual(o.undecided, ["unparsable": 1])
    }

    func testAuthFailureStopsRun() async throws {
        let d = try doc([line("b", alt: "c", flag: "divergent"), line("x", alt: "y", flag: "divergent")])
        let (q, p, r, w) = try await setup(d, mode: .text, replies: [HTTPReply(status: 401)])
        let o = await runAdjudication(d, questions: q, pages: p, mode: .text, reader: r, providerID: "p", model: "m")
        XCTAssertEqual(w.count, 1)
        XCTAssertNotNil(o.stoppedEarly)
        XCTAssertEqual(o.doc, d)
    }

    func testServerFailureKeepsLocalAndContinues() async throws {
        let d = try doc([line("b", alt: "c", flag: "divergent"), line("x", alt: "y", flag: "divergent")])
        let fails = (0..<OnlineReader.maxAttempts).map { _ in HTTPReply(status: 503) }
        let (q, p, r, w) = try await setup(d, mode: .text, replies: fails + [reply("{\"choice\": 1}")])
        let o = await runAdjudication(d, questions: q, pages: p, mode: .text, reader: r, providerID: "p", model: "m")
        XCTAssertEqual(o.doc.pages[0].lines[0].text, "b")
        XCTAssertEqual(Set(w.requests.compactMap { $0.url?.host }), ["api.example.com"])
    }
}
#endif
