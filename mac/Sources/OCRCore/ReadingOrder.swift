// src/book_render.py sort_reading_order 的移植：上到下、左到右，行高自适应分桶，
// 避免同一行被基线抖动拆成两桶。
//
// 与 Python 逐位一致的两个细节：
//   - Python 的 round() 是「四舍六入五成双」，这里用 .toNearestOrEven；
//   - Python 的 sorted() 是稳定排序，Swift 的 sorted 不保证，所以带原下标做最后的比较键。

public func sortReadingOrder(_ lines: [Line]) -> [Line] {
    guard !lines.isEmpty else { return lines }
    let heights = lines.map(\.h).filter { $0 > 0 }.sorted()
    let med = heights.isEmpty ? 1.0 : heights[heights.count / 2]
    let bucket = max(med * 0.6, 1.0)
    func row(_ l: Line) -> Double { ((l.y + l.h / 2) / bucket).rounded(.toNearestOrEven) }
    return lines.enumerated().sorted { a, b in
        let ra = row(a.element), rb = row(b.element)
        if ra != rb { return ra < rb }
        if a.element.x != b.element.x { return a.element.x < b.element.x }
        return a.offset < b.offset
    }.map(\.element)
}
