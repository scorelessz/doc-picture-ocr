import XCTest
@testable import OCRCore

final class BookLanguageTests: XCTestCase {
    func line(_ t: String, conf: Double = 0.85) -> Line {
        Line(x: 0, y: 0, w: 100, h: 20, conf: conf, text: t)
    }

    func testDefaultIsChineseAndUnchanged() {
        XCTAssertEqual(BookLanguage.default.id, "zh")
        XCTAssertEqual(BookLanguage.default.vision, ["zh-Hans", "zh-Hant", "en-US"])
        XCTAssertEqual(BookLanguage.default.transcribeHint, "")
        XCTAssertEqual(BookLanguage.default.adjudicationHint, "")
        let d = FuseRules(), z = FuseRules.forLanguage(.default)
        XCTAssertEqual(d.wCJK, z.wCJK)
        XCTAssertEqual(d.latinLetters, z.latinLetters)
    }

    func testFind() {
        XCTAssertEqual(BookLanguage.find("fr")?.vision.first, "fr-FR")
        XCTAssertEqual(BookLanguage.find("de")?.vision.first, "de-DE")
        XCTAssertNil(BookLanguage.find("xx"))
        XCTAssertNil(BookLanguage.find(nil))
        XCTAssertEqual(Set(BookLanguage.all.map(\.id)).count, BookLanguage.all.count)
    }

    func testAccentsAreNoiseOnlyInChineseRules() {
        XCTAssertEqual(noiseCount("café über Straße"), 3)
        XCTAssertEqual(noiseCount("café über Straße", latin: true), 0)
        XCTAssertEqual(noiseCount("« Ça va ? » „Ja“", latin: true), 0)
        XCTAssertEqual(noiseCount("Gar字on", latin: true), 1)
        XCTAssertEqual(noiseCount("中文", latin: false), 0)
    }

    func testLatinRulesKeepAccentedReading() {
        let fr = FuseRules.forLanguage(BookLanguage.find("fr")!)
        // PP-OCR（rapid）读出了重音，Vision 读丢了：西文规则下不再罚重音，平手取 PP-OCR
        XCTAssertFalse(visionWins(line("un cafe"), line("un café"), fr))
        // 中文规则下重音算噪声，Vision 的「cafe」反而赢：这就是要修的偏差
        XCTAssertTrue(visionWins(line("un cafe"), line("un café"), FuseRules()))
        // 西文书里误读成汉字的一方要输
        XCTAssertTrue(visionWins(line("Garçon"), line("Gar字on"), fr))
    }

    func testAccentedFragmentIsAWord() {
        XCTAssertTrue(hasWord("à"))
        XCTAssertTrue(hasWord("Ü"))
        XCTAssertFalse(hasWord("—"))
    }
}
