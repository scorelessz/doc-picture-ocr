import Foundation
import XCTest
@testable import OCRCore

final class ReadingOrderTests: XCTestCase {
    func line(_ x: Double, _ y: Double, _ t: String, h: Double = 20) -> Line {
        Line(x: x, y: y, w: 100, h: h, conf: 1, text: t)
    }

    func testTopToBottomThenLeftToRight() {
        let got = sortReadingOrder([line(300, 100, "b"), line(10, 200, "c"), line(10, 102, "a")])
        XCTAssertEqual(got.map(\.text), ["a", "b", "c"])
    }

    func testBaselineJitterStaysOnOneRow() {
        // 同一行两块，基线差 2 像素：行高 20 → 桶 12，中心 110 / 112 都落在桶 9，应按 x 排
        let got = sortReadingOrder([line(300, 102, "right"), line(10, 100, "left")])
        XCTAssertEqual(got.map(\.text), ["left", "right"])
    }

    func testStableForIdenticalKeys() {
        let got = sortReadingOrder([line(10, 100, "first"), line(10, 100, "second")])
        XCTAssertEqual(got.map(\.text), ["first", "second"])
    }

    func testBankersRoundingMatchesPython() {
        // 行高 10 → 桶 6；中心 y = 15 → 15/6 = 2.5，Python round(2.5) = 2；中心 21 → 3.5 → 4
        let a = Line(x: 50, y: 10, w: 10, h: 10, conf: 1, text: "a")   // 中心 15 → 桶 2
        let b = Line(x: 0, y: 16, w: 10, h: 10, conf: 1, text: "b")    // 中心 21 → 桶 4
        let c = Line(x: 10, y: 13, w: 10, h: 10, conf: 1, text: "c")   // 中心 18 → 3.0 → 桶 3
        XCTAssertEqual(sortReadingOrder([b, c, a]).map(\.text), ["a", "c", "b"])
    }
}

final class ContractTests: XCTestCase {
    func testSnakeCaseKeysMatchPythonContract() throws {
        let doc = EngineDoc(source: "x.pdf", engine: "vision", dpi: 300, pages: [
            PageDoc(page: 1, width: 10, height: 20, pdfWidth: 2.4, pdfHeight: 4.8, zoom: 4.1666,
                    nativeText: false, lines: [Line(x: 1, y: 2, w: 3, h: 4, conf: 0.5, text: "字")]),
        ])
        let data = try JSONEncoder().encode(doc)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let page = (obj["pages"] as! [[String: Any]])[0]
        for k in ["page", "width", "height", "pdf_width", "pdf_height", "zoom", "rotation", "native_text", "lines"] {
            XCTAssertNotNil(page[k], "missing key \(k)")
        }
        XCTAssertEqual(try JSONDecoder().decode(EngineDoc.self, from: data), doc)
    }

    func testTSVRoundTrip() {
        let l = Line(x: 1.25, y: 2, w: 3, h: 4, conf: 0.5, text: "a\tb")
        let s = tsvLine(l)
        XCTAssertEqual(s, "1.2\t2.0\t3.0\t4.0\t0.5000\ta b")
        XCTAssertEqual(parseTSV(s).first?.text, "a b")
    }
}
