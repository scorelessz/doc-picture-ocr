import XCTest
@testable import OCRCore

final class NormalizeTests: XCTestCase {
    func testFoldsWidthAndEllipsis() {
        XCTAssertEqual(norm("你好，世界……"), norm("你好,世界⋯⋯"))
        XCTAssertEqual(norm("a b\u{3000}c"), "abc")
    }

    func testEllipsisFoldsAfterNFKC() {
        XCTAssertEqual(norm("…"), norm("..."))
        XCTAssertEqual(norm("3.14"), "3.14")          // 单个句点不能吃掉
    }

    func testDoubleQuoteMapsToClosing() {
        // '"' 在两组里，后面的组覆盖前面的
        XCTAssertEqual(norm("\""), norm("”"))
        XCTAssertNotEqual(norm("“"), norm("”"))
    }

    func testPyStripMatchesPythonWhitespace() {
        XCTAssertEqual(pyStrip("\u{1C}\u{3000} 字 \u{85}"), "字")
        XCTAssertEqual(pyStrip("\u{200B}字"), "\u{200B}字")   // 零宽空格不是 Python 的空白
    }

    func testPyEqIsByCodePoint() {
        XCTAssertTrue("é" == "e\u{301}")                     // Swift 按规范等价
        XCTAssertFalse(pyEq("é", "e\u{301}"))                // Python 按码点
    }

    func testPyRound() {
        XCTAssertEqual(pyRound(0.12345, 4), 0.1235)          // 0.12345 的精确值略大于一半
        XCTAssertEqual(pyRound(0.5, 0), 0)                   // 恰好一半取偶
        XCTAssertEqual(pyRound(1.5, 0), 2)
    }
}

final class MatchTests: XCTestCase {
    func l(_ x: Double, _ y: Double, _ w: Double = 100, _ h: Double = 20, _ t: String = "x") -> Line {
        Line(x: x, y: y, w: w, h: h, conf: 1, text: t)
    }

    func testGreedyPairsByGeometry() {
        let (p, a, b) = matchLines([l(0, 0), l(0, 50)], [l(0, 52), l(0, 1), l(0, 200)])
        XCTAssertEqual(p.map(\.0), [0, 1])
        XCTAssertEqual(p.map(\.1), [1, 0])
        XCTAssertEqual(a, [])
        XCTAssertEqual(b, [2])
    }

    func testNoHorizontalOverlapNoPair() {
        let (p, a, b) = matchLines([l(0, 0)], [l(500, 0)])
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(a, [0])
        XCTAssertEqual(b, [0])
    }
}

final class AnomalyTests: XCTestCase {
    func testIsolatedCharBetweenCJK() {
        XCTAssertEqual(anomalyCount("一1道"), 1)
        XCTAssertEqual(anomalyCount("1994年"), 0)
    }

    func testBracketFamilyMismatch() {
        XCTAssertEqual(anomalyCount("【内容）"), 1)
        XCTAssertEqual(anomalyCount("（内容）"), 0)
    }

    func testHalfWidthPunctBetweenCJK() {
        XCTAssertEqual(anomalyCount("你好,世界"), 1)
    }

    func testBracketDefects() {
        XCTAssertEqual(bracketDefects("（内容"), 1)
        XCTAssertEqual(bracketDefects("内容）"), 1)
    }
}

final class FuseTests: XCTestCase {
    func l(_ x: Double, _ y: Double, _ w: Double, _ t: String, conf: Double = 0.9) -> Line {
        Line(x: x, y: y, w: w, h: 40, conf: conf, text: t)
    }

    func page(_ lines: [Line]) -> PageDoc {
        PageDoc(page: 1, width: 1000, height: 1000, pdfWidth: 200, pdfHeight: 200, zoom: 5, lines: lines)
    }

    func docs(_ v: [Line], _ r: [Line]) -> (EngineDoc, EngineDoc) {
        (EngineDoc(source: "a.pdf", engine: "vision", dpi: 360, pages: [page(v)]),
         EngineDoc(source: "a.pdf", engine: "rapidocr", dpi: 360, pages: [page(r)]))
    }

    /// P1 第 12 页的情形：同一行两个框各读一遍，单源那条开头带乱字，子串条件抓不到。
    func ghost() -> (EngineDoc, EngineDoc) {
        let body = "he answered, proffering his ungloved"
        return docs([l(100, 100, 900, "\"George Cuming,\" \(body)")],
                    [l(100, 100, 900, "\"George Cuming,\" \(body)"), l(300, 102, 700, "3”\(body)")])
    }

    func testNewRuleDropsNoisyGhostIntoAlt() throws {
        let (v, r) = ghost()
        let f = try fuse(v, r)
        XCTAssertEqual(f.pages[0].lines.count, 1)
        XCTAssertEqual(f.stats.droppedContained, 1)
        XCTAssertEqual(f.stats.onlyRapidocr, 0)
        XCTAssertTrue(f.pages[0].lines[0].alt?.hasPrefix("3”") ?? false)
    }

    func testLegacyKeepsNoisyGhost() throws {
        let (v, r) = ghost()
        var rules = FuseRules()
        rules.legacyContain = true
        let f = try fuse(v, r, rules: rules)
        XCTAssertEqual(f.pages[0].lines.count, 2)
        XCTAssertEqual(f.stats.droppedContained, 0)
        XCTAssertEqual(f.stats.onlyRapidocr, 1)
    }

    func testShortFragmentNeedsFullContainmentEvenWithNewRule() throws {
        // 3 个字、覆盖不到整行：不够 4 字，不能按相似度丢
        let (v, r) = docs([l(100, 100, 900, "他说话了很久很久")], [l(100, 100, 900, "他说话了很久很久"), l(300, 102, 200, "他说呀")])
        let f = try fuse(v, r)
        XCTAssertEqual(f.pages[0].lines.count, 2)
        XCTAssertEqual(f.stats.droppedContained, 0)
    }

    func testSubstringFragmentStillDropped() throws {
        let (v, r) = docs([l(100, 100, 900, "他说话了很久很久")], [l(100, 100, 900, "他说话了很久很久"), l(300, 102, 200, "很久")])
        XCTAssertEqual(try fuse(v, r).stats.droppedContained, 1)
    }

    func testLocalEditDistance() {
        func d(_ a: String, _ b: String) -> Int { localEditDistance(Array(a.unicodeScalars), Array(b.unicodeScalars)) }
        XCTAssertEqual(d("abc", "xxabcxx"), 0)
        XCTAssertEqual(d("abc", "xxadcxx"), 1)
        XCTAssertEqual(d("abc", ""), 3)
    }

    /// P1 第 236 页：几何几乎重合，OCR 替换把公共子串切碎。
    func testSubstitutionsNoLongerHideGhost() throws {
        let (v, r) = docs([l(100, 100, 900, "No other Priest must comc, Tom! It is not")],
                          [l(100, 100, 900, "No other Priest must comc, Tom! It is not"),
                           l(110, 101, 880, "No other priest must come, Tom! It is not")])
        let f = try fuse(v, r)
        XCTAssertEqual(f.pages[0].lines.count, 1)
        XCTAssertEqual(f.stats.droppedContained, 1)
        var rules = FuseRules()
        rules.legacyContain = true
        XCTAssertEqual(try fuse(v, r, rules: rules).pages[0].lines.count, 2)
    }

    func testRelaxedThresholdNeedsHighGeometry() throws {
        // 距离比 0.2：几何不够高（水平只盖住 70%）时不能按相似度丢
        let host = "abcdefghijklmnopqrstuvwxyz"
        let (v, r) = docs([l(100, 100, 400, host)], [l(100, 100, 400, host), l(220, 102, 400, "abcdefgXXXXlmnopqrst")])
        XCTAssertEqual(try fuse(v, r).stats.droppedContained, 0)
    }

    func testShortLineDoesNotRelax() throws {
        // 6 字，距离比 1/6，几何完全重合：短行不放宽
        let (v, r) = docs([l(100, 100, 900, "他说话了很久很久")], [l(100, 100, 900, "他说话了很久很久"), l(100, 100, 900, "他说呀了很久")])
        XCTAssertEqual(try fuse(v, r).stats.droppedContained, 0)
    }

    func testSingleSourceLineIsKept() throws {
        let (v, r) = docs([l(100, 100, 900, "只有 Vision 读到")], [])
        let f = try fuse(v, r)
        XCTAssertEqual(f.pages[0].lines.map(\.src), ["vision"])
        XCTAssertEqual(f.stats.onlyVision, 1)
    }

    func testLeadingChapterNumberKept() throws {
        let (v, r) = docs([l(100, 100, 900, "雪天的客人")], [l(100, 100, 900, "二雪天的客人")])
        let f = try fuse(v, r)
        XCTAssertEqual(f.pages[0].lines[0].text, "二雪天的客人")
        XCTAssertEqual(f.pages[0].lines[0].flag, "divergent")
    }

    func testAltEncodesAsNull() throws {
        let (v, r) = docs([l(100, 100, 900, "相同")], [l(100, 100, 900, "相同")])
        let data = try JSONEncoder().encode(try fuse(v, r))
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let line = ((json["pages"] as! [[String: Any]])[0]["lines"] as! [[String: Any]])[0]
        XCTAssertTrue(line["alt"] is NSNull)
    }

    func testSizeMismatchThrows() {
        var (v, r) = docs([], [])
        r.pages[0].width = 2000
        XCTAssertThrowsError(try fuse(v, r))
        v.engine = "rapidocr"
        XCTAssertThrowsError(try fuse(v, r))
    }
}

final class LogTests: XCTestCase {
    func testConfigureStripsOptions() throws {
        let l = Log()
        let rest = try l.configure(["book", "a.pdf", "--log-level", "debug", "--log-format", "text", "--force", "--log-text"], env: [:])
        XCTAssertEqual(rest, ["book", "a.pdf", "--force"])
        XCTAssertEqual(l.level, .debug)
        XCTAssertTrue(l.withText)
    }

    func testEnvIsEquivalentAndFlagWins() throws {
        let a = Log(), b = Log()
        _ = try a.configure(["x"], env: ["DOCOCR_LOG": "trace"])
        XCTAssertEqual(a.level, .trace)
        _ = try b.configure(["--log-level", "warn"], env: ["DOCOCR_LOG": "trace"])
        XCTAssertEqual(b.level, .warn)
    }

    func testOffByDefault() throws {
        let l = Log()
        _ = try l.configure(["x"], env: [:])
        XCTAssertFalse(l.enabled)
        XCTAssertFalse(l.withText)
    }

    func testBadLevelThrows() {
        XCTAssertThrowsError(try Log().configure(["--log-level", "loud"], env: [:]))
    }
}

final class VLMFuseTests: XCTestCase {
    func page(_ lines: [FusedLine], noInk: Bool? = nil) -> FusedPage {
        FusedPage(page: 1, width: 1000, height: 1000, pdfWidth: 200, pdfHeight: 200, zoom: 5, rotation: 0, image: nil,
                  nativeText: false, lines: lines, noInk: noInk)
    }

    func line(_ y: Double, _ t: String, alt: String? = nil) -> FusedLine {
        FusedLine(x: 0, y: y, w: 500, h: 30, text: t, conf: 0.9, src: "both", alt: alt, flag: alt == nil ? "ok" : "divergent")
    }

    func testThirdVoteFlipsToLoser() {
        let (p, r) = applyVLM(page([line(0, "the cat sal down", alt: "the cat sat down")]), vlm: "the cat sat down")
        XCTAssertEqual(p.lines[0].text, "the cat sat down")
        XCTAssertEqual(r.flips.count, 1)
    }

    func testNoFlipWithoutDivergence() {
        let (p, r) = applyVLM(page([line(0, "the cat sal down")]), vlm: "the cat sat down")
        XCTAssertEqual(p.lines[0].text, "the cat sal down")     // 字形信 CTC
        XCTAssertEqual(r.flips.count, 0)
    }

    func testVLMOnlyTextStaysOutOfBody() {
        let (p, r) = applyVLM(page([line(0, "real line of text")]), vlm: "real line of text and a whole invented sentence")
        XCTAssertEqual(p.lines.map(\.text), ["real line of text"])
        XCTAssertEqual(r.orphans.count, 1)
    }

    func testNoInkPageNotCalled() {
        let (p, r) = applyVLM(page([], noInk: true), vlm: "fabricated")
        XCTAssertTrue(r.skippedNoInk)
        XCTAssertTrue(p.lines.isEmpty)
    }

    func testVLMBreakMarksParagraphStart() {
        let (p, _) = applyVLM(page([line(0, "first line of a"), line(40, "paragraph here"), line(80, "second paragraph")]),
                              vlm: "first line of a paragraph here\nsecond paragraph")
        XCTAssertNil(p.lines[0].vlmBreak)          // 页首可能是上一页的续段，不判断
        XCTAssertEqual(p.lines[1].vlmBreak, false)
        XCTAssertEqual(p.lines[2].vlmBreak, true)
    }

    func testLoopCut() {
        let g = gateVLM(String(repeating: "abcdefghijklmnopqrstuvwxyz", count: 12), estimate: 10000)
        XCTAssertTrue(g.loopCut)
        XCTAssertLessThan(g.keptChars, 60)
    }

    func testLengthCap() {
        var s = ""
        for i in 0..<400 { s += "\(i)," }
        let g = gateVLM(s, estimate: 100)
        XCTAssertTrue(g.truncatedByLength)
        XCTAssertEqual(g.keptChars, 200)
    }
}
