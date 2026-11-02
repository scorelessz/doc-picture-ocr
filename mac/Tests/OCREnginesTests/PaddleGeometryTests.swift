import XCTest
@testable import OCREngines

final class PaddleGeometryTests: XCTestCase {
    func rect(_ x: Double, _ y: Double, _ w: Double, _ h: Double) -> [P2] {
        [P2(x: x, y: y), P2(x: x + w, y: y), P2(x: x + w, y: y + h), P2(x: x, y: y + h)]
    }

    func testMinAreaRectOfAxisAlignedBox() {
        let r = minAreaRect(convexHull(rect(10, 20, 100, 30)))!
        XCTAssertEqual(max(r.w, r.h), 100, accuracy: 1e-9)
        XCTAssertEqual(min(r.w, r.h), 30, accuracy: 1e-9)
    }

    func testMiniBoxOrder() {
        let b = miniBox(minAreaRect(convexHull(rect(10, 20, 100, 30)))!)
        XCTAssertEqual(b[0].x, 10, accuracy: 1e-9)      // 左上
        XCTAssertEqual(b[0].y, 20, accuracy: 1e-9)
        XCTAssertEqual(b[2].x, 110, accuracy: 1e-9)     // 右下
        XCTAssertEqual(b[2].y, 50, accuracy: 1e-9)
    }

    func testRoundOffsetExpandsEachSide() {
        let r = minAreaRect(convexHull(roundOffset(rect(10, 20, 100, 30), 5)))!
        XCTAssertEqual(max(r.w, r.h), 110, accuracy: 1.01)
        XCTAssertEqual(min(r.w, r.h), 40, accuracy: 1.01)
    }

    func testSortedBoxesGroupsLines() {
        let b = [DetBox(pts: rect(200, 104, 10, 10), score: 1), DetBox(pts: rect(10, 100, 10, 10), score: 1),
                 DetBox(pts: rect(10, 200, 10, 10), score: 1)]
        XCTAssertEqual(sortedBoxes(b).map(\.pts[0].x), [10, 200, 10])
    }

    func testAxisAlignedCropIsExact() {
        var px = [UInt8](repeating: 0, count: 100)
        for i in 0..<100 { px[i] = UInt8(i) }
        let c = cropLine(Gray(w: 10, h: 10, px: px), rect(2, 3, 4, 2))
        XCTAssertEqual(c.px, [32, 33, 34, 35, 42, 43, 44, 45])
    }

    func testResizeKeepsFlatImage() {
        let g = Gray(w: 8, h: 8, px: [UInt8](repeating: 200, count: 64)).resized(3, 5)
        XCTAssertEqual(g.px, [UInt8](repeating: 200, count: 15))
    }

    func testDBFindsOneBox() {
        var p = [Float](repeating: 0, count: 200 * 100)
        for y in 40..<60 { for x in 20..<180 { p[y * 200 + x] = 0.9 } }
        let b = p.withUnsafeBufferPointer { dbPostprocess($0, w: 200, h: 100, destW: 200, destH: 100) }
        XCTAssertEqual(b.count, 1)
        XCTAssertLessThan(b[0].pts[0].x, 20)
        XCTAssertGreaterThan(b[0].pts[2].x, 179)
    }
}
