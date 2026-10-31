import XCTest
@testable import OCRCore

final class BookLayoutTests: XCTestCase {
    // 1000×1400 的页，正文 x 100~900，行高 40，行距 60，版心 y 200~1200
    func body(_ text: String, _ y: Double, x: Double = 100, w: Double = 800, h: Double = 40) -> MDLine {
        MDLine(x: x, y: y, w: w, h: h, text: text, conf: 0.9, src: "both", flag: "ok")
    }

    func fill(_ n: Int = 10, from y0: Double = 200) -> [MDLine] {
        (0..<n).map { body("这是一行满满当当的正文内容第\($0)行", y0 + Double($0) * 60) }
    }

    func page(_ n: Int, _ lines: [MDLine]) -> MDPage { MDPage(page: n, width: 1000, height: 1400, lines: lines) }

    func run(_ pages: [MDPage], marks: Bool = true) -> (md: String, stats: MDStats) {
        var o = MDOptions()
        o.pageMarks = marks
        return toMarkdown(MDDoc(pages: pages), options: o)
    }

    // MARK: 页码

    func testPageNumberKinds() {
        XCTAssertEqual(pageNumberKind("17"), .arabic)
        XCTAssertEqual(pageNumberKind("— 17 —"), .arabic)
        XCTAssertEqual(pageNumberKind("1998"), .long)
        XCTAssertEqual(pageNumberKind("xvii"), .roman)
        XCTAssertEqual(pageNumberKind("三"), .cjk)
        XCTAssertNil(pageNumberKind("mix"))                  // 砍掉 m/d/c，普通英文词不是页码
        XCTAssertNil(pageNumberKind("——"))
        XCTAssertNil(pageNumberKind("第三章"))
    }

    func testPageNumberSequenceRemoved() {
        let pages = (1...4).map { page($0, fill() + [body("\($0 + 10)", 1300, x: 480, w: 40)]) }
        let r = run(pages)
        XCTAssertEqual(r.stats.droppedDetail["页码"], 4)
        XCTAssertFalse(r.md.contains("11"))
    }

    func testIsolatedCJKNumberIsKept() {
        // 孤零零一个「三」要有同一位置逐页出现的证据才算页码：小节号不能被删
        let pages = (1...8).map { n in
            page(n, fill() + (n == 3 ? [body("三", 1300, x: 480, w: 40)] : []))
        }
        let r = run(pages)
        XCTAssertNil(r.stats.droppedDetail["页码"])
        XCTAssertTrue(r.md.contains("三"))
    }

    // MARK: 书眉

    func testRunningHeadRemovedCrossPage() {
        let pages = (1...4).map { page($0, [body("失约之城", 60, x: 420, w: 160)] + fill()) }
        let r = run(pages)
        XCTAssertEqual(r.stats.droppedDetail["书眉/页脚(跨页重复)"], 4)
        XCTAssertFalse(r.md.contains("失约之城"))
    }

    func testSizeGateProtectsLargerChapterTitle() {
        // 与书眉同文、同位置，但字号比正文大：书眉绝不比正文大，所以不能删
        let pages = (1...4).map { n in
            page(n, [body("失约之城", 60, x: 420, w: 160, h: n == 1 ? 80 : 40)] + fill())
        }
        let r = run(pages)
        XCTAssertEqual(r.stats.droppedDetail["书眉/页脚(跨页重复)"], 3)
        XCTAssertTrue(r.md.contains("失约之城"))
    }

    func testFuzzyHeadNeedsLength() {
        let heads: Set<Key> = [headKey("灯下的来信")]
        XCTAssertTrue(fuzzyHead(headKey("灯下的来"), heads))
        XCTAssertFalse(fuzzyHead(headKey("来信"), heads))
    }

    // MARK: 段落与跨页

    func testCrossPageMergeAndInlineMark() {
        let r = run([page(1, fill()), page(2, fill())])
        XCTAssertEqual(r.stats.paragraphs, 1)
        XCTAssertTrue(r.md.contains("第9行<!-- page 2 -->这是"), "续行的页标记必须留在段落内")
    }

    func testMarkOwnLineAtParagraphBoundary() {
        // 第 1 页末行短：段落结束，第 2 页标记单独成行
        var p1 = fill()
        p1[9] = body("短行结束。", 740, w: 200)
        let r = run([page(1, p1), page(2, fill())])
        XCTAssertEqual(r.stats.paragraphs, 2)
        XCTAssertTrue(r.md.contains("短行结束。\n\n<!-- page 2 -->\n\n这是"))
    }

    func testNoPageMarks() {
        XCTAssertFalse(run([page(1, fill()), page(2, fill())], marks: false).md.contains("<!--"))
    }

    func testSpliceRules() {
        XCTAssertEqual(joinSplice("post-", "marked"), "postmarked")
        XCTAssertEqual(joinSplice("lazy", "dog"), "lazy dog")
        XCTAssertEqual(joinSplice("中文", "继续"), "中文继续")
        XCTAssertEqual(joinSplice("a-", "中"), "a-中")
    }

    func joinSplice(_ a: String, _ b: String) -> String {
        let (x, y, z) = splice(a, b)
        return x + y + z
    }

    // MARK: 标题 / 版面

    func testChapterHeadingLevels() {
        let r = run([page(1, [body("第三章 归途", 100, x: 380, w: 240, h: 70)] + fill())])
        XCTAssertTrue(r.md.contains("# 第三章 归途"))
        XCTAssertEqual(r.stats.headings, 1)
    }

    func testVerticalPageWarnsAndKeepsLines() {
        let lines = (0..<6).map { MDLine(x: 800 - Double($0) * 120, y: 100, w: 40, h: 900, text: "竖排第\($0)列", conf: 0.9) }
        let r = run([page(1, lines)])
        XCTAssertEqual(r.stats.verticalPages, [1])
        XCTAssertTrue(r.md.contains("疑似竖排"))
        XCTAssertTrue(r.md.contains("竖排第5列"))
    }

    func testTwoColumnPageSplits() {
        let lines = (0..<10).flatMap { i -> [MDLine] in
            let y = 200 + Double(i) * 60
            return [body("左栏第\(i)行文字内容", y, x: 100, w: 340), body("右栏第\(i)行文字内容", y, x: 560, w: 340)]
        }
        let r = run([page(1, lines)])
        XCTAssertEqual(r.stats.twoColumnPages, [1])
        XCTAssertLessThan(r.md.range(of: "左栏第9行")!.lowerBound, r.md.range(of: "右栏第0行")!.lowerBound)
    }

    func testNoiseIsCountedNotSilent() {
        let r = run([page(1, fill() + [body("。", 1000, x: 500, w: 20)])])
        XCTAssertEqual(r.stats.droppedDetail["孤立标点或无文字碎块"], 1)
        XCTAssertEqual(r.stats.droppedLines.first?.text, "。")
    }

    func testMalformedLineKeepsText() {
        let r = run([page(1, [MDLine(x: nil, y: 100, w: 100, h: 40, text: "缺坐标的行")])])
        XCTAssertEqual(r.stats.malformedLines, 1)
        XCTAssertTrue(r.md.contains("缺坐标的行"))
    }

    func testMarkLineHeader() {
        XCTAssertEqual(withMark("\n正文\n"), "<!-- generated-by: book-line -->\n\n正文\n")
    }
}
