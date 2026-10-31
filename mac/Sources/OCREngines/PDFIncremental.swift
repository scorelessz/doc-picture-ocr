#if canImport(PDFKit)
import Compression
import Foundation

// 最小 PDF 读取器 + 增量更新写入：可搜索 PDF 的底座。
//
// 为什么不用 CoreGraphics：CGContext.drawPDFPage 是重画，实测把英文基准书带 SMask 的 JPX 前景层
// 转成了 FlateDecode，「原图字节不变」直接破功。增量更新只在文件尾追加对象，源文件字节一个不动。
//
// 只读需要的东西：xref 表 / xref 流（含 /Prev、/XRefStm）、对象流、页树（含继承属性）。

public enum PDFError: Error, CustomStringConvertible {
    case malformed(String), encrypted, unsupportedFilter(String)

    public var description: String {
        switch self {
        case .malformed(let s): return "PDF 结构解析失败: \(s)"
        case .encrypted: return "加密 PDF 不支持嵌字"
        case .unsupportedFilter(let f): return "不支持的流过滤器: \(f)"
        }
    }
}

public indirect enum PDFValue {
    case null
    case bool(Bool)
    case number(String)                 // 原样保留，不做浮点往返
    case name(String)                   // 不含斜杠，保留原始 #xx 写法
    case string([UInt8])                // 含定界符的原始字节
    case array([PDFValue])
    case dict([(String, PDFValue)])     // 保持原顺序
    case ref(Int, Int)

    var dictItems: [(String, PDFValue)]? {
        if case .dict(let d) = self { return d }
        return nil
    }

    subscript(key: String) -> PDFValue? {
        dictItems?.first { $0.0 == key }?.1
    }

    var double: Double? {
        if case .number(let s) = self { return Double(s) }
        return nil
    }

    var int: Int? { double.map { Int($0) } }

    func serialize(into o: inout [UInt8]) {
        switch self {
        case .null: o += Array("null".utf8)
        case .bool(let b): o += Array((b ? "true" : "false").utf8)
        case .number(let s): o += Array(s.utf8)
        case .name(let s): o += Array("/\(s)".utf8)
        case .string(let b): o += b
        case .array(let a):
            o.append(0x5B)
            for (i, v) in a.enumerated() {
                if i > 0 { o.append(0x20) }
                v.serialize(into: &o)
            }
            o.append(0x5D)
        case .dict(let d):
            o += Array("<<".utf8)
            for (k, v) in d {
                o += Array("/\(k) ".utf8)
                v.serialize(into: &o)
                o.append(0x20)
            }
            o += Array(">>".utf8)
        case .ref(let n, let g): o += Array("\(n) \(g) R".utf8)
        }
    }
}

private func isWS(_ c: UInt8) -> Bool { c == 0 || c == 9 || c == 10 || c == 12 || c == 13 || c == 32 }
private func isDelim(_ c: UInt8) -> Bool { "()<>[]{}/%".utf8.contains(c) }

struct PDFLexer {
    let d: [UInt8]
    var i: Int

    mutating func skipWS() {
        while i < d.count {
            if isWS(d[i]) {
                i += 1
            } else if d[i] == 0x25 {             // % 注释
                while i < d.count, d[i] != 10, d[i] != 13 { i += 1 }
            } else {
                break
            }
        }
    }

    mutating func keyword() -> String {
        skipWS()
        let s = i
        while i < d.count, !isWS(d[i]), !isDelim(d[i]) { i += 1 }
        return String(decoding: d[s..<i], as: UTF8.self)
    }

    func starts(_ s: String, at p: Int? = nil) -> Bool {
        let u = Array(s.utf8), at = p ?? i
        return at + u.count <= d.count && d[at..<(at + u.count)].elementsEqual(u)
    }

    mutating func value() throws -> PDFValue {
        skipWS()
        guard i < d.count else { throw PDFError.malformed("意外的文件尾") }
        let c = d[i]
        switch c {
        case 0x2F:                               // /name
            i += 1
            let s = i
            while i < d.count, !isWS(d[i]), !isDelim(d[i]) { i += 1 }
            return .name(String(decoding: d[s..<i], as: UTF8.self))
        case 0x28:                               // (string)
            let s = i
            var depth = 0
            while i < d.count {
                if d[i] == 0x5C { i += 2; continue }
                if d[i] == 0x28 { depth += 1 } else if d[i] == 0x29 {
                    depth -= 1
                    if depth == 0 { i += 1; break }
                }
                i += 1
            }
            return .string(Array(d[s..<min(i, d.count)]))
        case 0x3C:
            if i + 1 < d.count, d[i + 1] == 0x3C {
                i += 2
                var items: [(String, PDFValue)] = []
                while true {
                    skipWS()
                    guard i < d.count else { throw PDFError.malformed("字典未闭合") }
                    if starts(">>") { i += 2; break }
                    guard case .name(let k) = try value() else { throw PDFError.malformed("字典键不是名字") }
                    items.append((k, try value()))
                }
                return .dict(items)
            }
            let s = i
            while i < d.count, d[i] != 0x3E { i += 1 }
            i += 1
            return .string(Array(d[s..<min(i, d.count)]))
        case 0x5B:
            i += 1
            var items: [PDFValue] = []
            while true {
                skipWS()
                guard i < d.count else { throw PDFError.malformed("数组未闭合") }
                if d[i] == 0x5D { i += 1; break }
                items.append(try value())
            }
            return .array(items)
        default:
            let s = i
            let k = keyword()
            if k.isEmpty { i += 1; throw PDFError.malformed("非法字符 @\(s)") }
            switch k {
            case "true": return .bool(true)
            case "false": return .bool(false)
            case "null": return .null
            default: break
            }
            guard Double(k) != nil else { throw PDFError.malformed("非法记号 \(k) @\(s)") }
            // 回看 "n g R"
            if Int(k) != nil {
                let save = i
                let g = keyword()
                if Int(g) != nil, keyword() == "R" { return .ref(Int(k)!, Int(g)!) }
                i = save
            }
            return .number(k)
        }
    }
}

func inflate(_ src: [UInt8]) throws -> [UInt8] {
    guard src.count > 2 else { return [] }
    var cap = max(src.count * 6, 1 << 16)
    while cap < 1 << 30 {
        var dst = [UInt8](repeating: 0, count: cap)
        let n = src[2...].withUnsafeBufferPointer { s in
            compression_decode_buffer(&dst, cap, s.baseAddress!, s.count, nil, COMPRESSION_ZLIB)
        }
        if n > 0, n < cap { return Array(dst[..<n]) }
        cap *= 4
    }
    throw PDFError.malformed("解压失败")
}

func deflate(_ src: [UInt8]) -> [UInt8] {
    var dst = [UInt8](repeating: 0, count: src.count + 4096)
    let n = compression_encode_buffer(&dst, dst.count, src, src.count, nil, COMPRESSION_ZLIB)
    var a: UInt32 = 1, b: UInt32 = 0
    for c in src {
        a = (a + UInt32(c)) % 65521
        b = (b + a) % 65521
    }
    let adler = (b << 16) | a
    return [0x78, 0x9C] + dst[..<n]
        + [UInt8(adler >> 24), UInt8((adler >> 16) & 255), UInt8((adler >> 8) & 255), UInt8(adler & 255)]
}

/// PNG 预测器（xref 流常用 /Predictor 12）。
private func unpredict(_ b: [UInt8], columns: Int) -> [UInt8] {
    let row = columns + 1
    var out: [UInt8] = [], prev = [UInt8](repeating: 0, count: columns)
    var p = 0
    while p + row <= b.count {
        let t = b[p]
        var cur = Array(b[(p + 1)..<(p + row)])
        for i in 0..<columns {
            let a = i > 0 ? Int(cur[i - 1]) : 0, up = Int(prev[i]), c = i > 0 ? Int(prev[i - 1]) : 0
            let v = Int(cur[i])
            switch t {
            case 1: cur[i] = UInt8((v + a) & 255)
            case 2: cur[i] = UInt8((v + up) & 255)
            case 3: cur[i] = UInt8((v + (a + up) / 2) & 255)
            case 4:
                let q = a + up - c, pa = abs(q - a), pb = abs(q - up), pc = abs(q - c)
                cur[i] = UInt8((v + (pa <= pb && pa <= pc ? a : (pb <= pc ? up : c))) & 255)
            default: break
            }
        }
        out += cur
        prev = cur
        p += row
    }
    return out
}

public struct PDFPageRef {
    public let obj: Int, gen: Int
    public let dict: PDFValue
    public let resources: PDFValue?
    public let media: [Double], crop: [Double]    // x0 y0 x1 y1，已规范化，crop 已与 media 求交
    public let rotation: Int
}

public final class PDFFile {
    public let bytes: [UInt8]
    enum Loc { case offset(Int, Int), inStream(Int, Int), free }
    var xref: [Int: Loc] = [:]
    public private(set) var trailer: PDFValue = .dict([])
    public private(set) var lastXRefOffset = 0
    public private(set) var usesXRefStream = false
    private var objStreams: [Int: (first: Int, offsets: [Int: Int], data: [UInt8])] = [:]

    public init(_ data: [UInt8]) throws {
        bytes = data
        guard let sx = PDFFile.findLast(data, "startxref") else { throw PDFError.malformed("找不到 startxref") }
        var lx = PDFLexer(d: data, i: sx + 9)
        guard let off = Int(lx.keyword()) else { throw PDFError.malformed("startxref 无效") }
        lastXRefOffset = off
        var seen = Set<Int>()
        try loadChain(off, &seen, first: true)
        if trailer["Encrypt"] != nil { throw PDFError.encrypted }
    }

    private static func findLast(_ d: [UInt8], _ s: String) -> Int? {
        let u = Array(s.utf8)
        var i = d.count - u.count
        while i >= 0 {
            if d[i] == u[0], d[i..<(i + u.count)].elementsEqual(u) { return i }
            i -= 1
        }
        return nil
    }

    private func setEntry(_ n: Int, _ l: Loc) {
        if xref[n] == nil { xref[n] = l }        // 先读到的是最新的
    }

    private func loadChain(_ off: Int, _ seen: inout Set<Int>, first: Bool) throws {
        guard off >= 0, off < bytes.count, seen.insert(off).inserted else { return }
        var lx = PDFLexer(d: bytes, i: off)
        lx.skipWS()
        var tr: PDFValue
        if lx.starts("xref") {
            lx.i += 4
            while true {
                lx.skipWS()
                if lx.starts("trailer") { lx.i += 7; break }
                guard let start = Int(lx.keyword()), let count = Int(lx.keyword()) else {
                    throw PDFError.malformed("xref 子节头无效")
                }
                for k in 0..<count {
                    guard let o = Int(lx.keyword()), let g = Int(lx.keyword()) else {
                        throw PDFError.malformed("xref 条目无效")
                    }
                    let t = lx.keyword()
                    setEntry(start + k, t == "n" ? .offset(o, g) : .free)
                }
            }
            tr = try lx.value()
            if let x = tr["XRefStm"]?.int { try loadChain(x, &seen, first: false) }
        } else {
            let (_, v, raw) = try parseIndirect(at: off)
            guard let raw else { throw PDFError.malformed("xref 流缺数据") }
            tr = v
            if first { usesXRefStream = true }
            let w = (v["W"].flatMap { x -> [Int]? in
                if case .array(let a) = x { return a.compactMap(\.int) }
                return nil
            }) ?? []
            guard w.count == 3 else { throw PDFError.malformed("xref 流 W 无效") }
            var body = try decodeStream(v, raw)
            if let parms = v["DecodeParms"], let pred = parms["Predictor"]?.int, pred >= 10 {
                body = unpredict(body, columns: parms["Columns"]?.int ?? 1)
            }
            var index: [Int] = [0, v["Size"]?.int ?? 0]
            if case .array(let a)? = v["Index"] { index = a.compactMap(\.int) }
            var p = 0
            let rowLen = w.reduce(0, +)
            for s in stride(from: 0, to: index.count - 1, by: 2) {
                for k in 0..<index[s + 1] {
                    guard p + rowLen <= body.count else { break }
                    func field(_ o: Int, _ l: Int) -> Int { body[(p + o)..<(p + o + l)].reduce(0) { $0 << 8 | Int($1) } }
                    let t = w[0] == 0 ? 1 : field(0, w[0])
                    let a = field(w[0], w[1]), b = field(w[0] + w[1], w[2])
                    switch t {
                    case 0: setEntry(index[s] + k, .free)
                    case 1: setEntry(index[s] + k, .offset(a, b))
                    case 2: setEntry(index[s] + k, .inStream(a, b))
                    default: break
                    }
                    p += rowLen
                }
            }
        }
        if first { trailer = tr }
        if let prev = tr["Prev"]?.int { try loadChain(prev, &seen, first: false) }
    }

    /// 解析 "n g obj ... [stream]"，返回 (对象号, 值, 流的原始字节)。
    private func parseIndirect(at off: Int) throws -> (Int, PDFValue, [UInt8]?) {
        var lx = PDFLexer(d: bytes, i: off)
        guard let n = Int(lx.keyword()), Int(lx.keyword()) != nil, lx.keyword() == "obj" else {
            throw PDFError.malformed("对象头无效 @\(off)")
        }
        let v = try lx.value()
        lx.skipWS()
        guard lx.starts("stream") else { return (n, v, nil) }
        lx.i += 6
        if lx.i < bytes.count, bytes[lx.i] == 13 { lx.i += 1 }
        if lx.i < bytes.count, bytes[lx.i] == 10 { lx.i += 1 }
        guard var len = try v["Length"].map(resolve)?.int else { throw PDFError.malformed("流缺 Length") }
        len = min(len, bytes.count - lx.i)
        return (n, v, Array(bytes[lx.i..<(lx.i + len)]))
    }

    private func decodeStream(_ dict: PDFValue, _ raw: [UInt8]) throws -> [UInt8] {
        guard let f = dict["Filter"] else { return raw }
        var names: [String] = []
        if case .name(let n) = f { names = [n] }
        if case .array(let a) = f { names = a.compactMap { if case .name(let n) = $0 { return n } else { return nil } } }
        var out = raw
        for n in names {
            guard n == "FlateDecode" || n == "Fl" else { throw PDFError.unsupportedFilter(n) }
            out = try inflate(out)
        }
        return out
    }

    public func object(_ n: Int) throws -> PDFValue {
        switch xref[n] {
        case .offset(let o, _)?:
            return try parseIndirect(at: o).1
        case .inStream(let stm, _)?:
            let s = try objectStream(stm)
            guard let off = s.offsets[n] else { throw PDFError.malformed("对象流 \(stm) 没有 \(n)") }
            var lx = PDFLexer(d: s.data, i: s.first + off)
            return try lx.value()
        default:
            return .null
        }
    }

    private func objectStream(_ n: Int) throws -> (first: Int, offsets: [Int: Int], data: [UInt8]) {
        if let s = objStreams[n] { return s }
        guard case .offset(let o, _)? = xref[n] else { throw PDFError.malformed("对象流 \(n) 位置无效") }
        let (_, v, raw) = try parseIndirect(at: o)
        guard let raw, let cnt = v["N"]?.int, let first = v["First"]?.int else { throw PDFError.malformed("对象流 \(n) 字典无效") }
        let data = try decodeStream(v, raw)
        var lx = PDFLexer(d: data, i: 0), offsets: [Int: Int] = [:]
        for _ in 0..<cnt {
            guard let a = Int(lx.keyword()), let b = Int(lx.keyword()) else { break }
            offsets[a] = b
        }
        let s = (first, offsets, data)
        objStreams[n] = s
        return s
    }

    public func resolve(_ v: PDFValue) throws -> PDFValue {
        var cur = v, depth = 0
        while case .ref(let n, _) = cur, depth < 32 {
            cur = try object(n)
            depth += 1
        }
        return cur
    }

    private func box(_ v: PDFValue?) throws -> [Double]? {
        guard let v, case .array(let a) = try resolve(v) else { return nil }
        let n = try a.compactMap { try resolve($0).double }
        guard n.count == 4 else { return nil }
        return [min(n[0], n[2]), min(n[1], n[3]), max(n[0], n[2]), max(n[1], n[3])]
    }

    /// 按页序列出所有页，继承属性已解析。
    public func pages() throws -> [PDFPageRef] {
        guard let rootRef = trailer["Root"] else { throw PDFError.malformed("trailer 缺 Root") }
        let root = try resolve(rootRef)
        guard let pagesRef = root["Pages"] else { throw PDFError.malformed("Catalog 缺 Pages") }
        var out: [PDFPageRef] = []
        var seen = Set<Int>()

        struct Inherit { var res: PDFValue?, media: PDFValue?, crop: PDFValue?, rot: PDFValue? }

        func walk(_ ref: PDFValue, _ inh: Inherit) throws {
            guard case .ref(let n, let g) = ref, seen.insert(n).inserted else { return }
            let node = try object(n)
            var cur = inh
            if let v = node["Resources"] { cur.res = v }
            if let v = node["MediaBox"] { cur.media = v }
            if let v = node["CropBox"] { cur.crop = v }
            if let v = node["Rotate"] { cur.rot = v }
            if let kids = node["Kids"], case .array(let a) = try resolve(kids) {
                for k in a { try walk(k, cur) }
                return
            }
            guard let media = try box(cur.media) else { throw PDFError.malformed("第 \(out.count + 1) 页缺 MediaBox") }
            var crop = try box(cur.crop) ?? media
            crop = [max(crop[0], media[0]), max(crop[1], media[1]), min(crop[2], media[2]), min(crop[3], media[3])]
            if crop[2] <= crop[0] || crop[3] <= crop[1] { crop = media }
            let rot = try cur.rot.map(resolve)?.int ?? 0
            out.append(PDFPageRef(obj: n, gen: g, dict: node, resources: cur.res, media: media, crop: crop,
                                  rotation: ((rot % 360) + 360) % 360))
        }

        try walk(pagesRef, Inherit())
        return out
    }
}

/// 增量更新写入器：追加对象 + 新的 xref 节。
public final class PDFUpdater {
    let file: PDFFile
    var nextObj: Int
    var objects: [(num: Int, gen: Int, body: [UInt8])] = []

    public init(_ f: PDFFile) throws {
        file = f
        guard let size = f.trailer["Size"]?.int else { throw PDFError.malformed("trailer 缺 Size") }
        nextObj = size
    }

    public func allocate() -> Int {
        defer { nextObj += 1 }
        return nextObj
    }

    public func setObject(_ n: Int, gen: Int = 0, _ v: PDFValue) {
        var b: [UInt8] = []
        v.serialize(into: &b)
        objects.append((n, gen, b))
    }

    public func setStream(_ n: Int, dict: [(String, PDFValue)] = [], data: [UInt8], compress: Bool = true) {
        var d = dict
        var payload = data
        if compress {
            let z = deflate(data)
            if z.count < data.count {
                payload = z
                d.append(("Filter", .name("FlateDecode")))
            }
        }
        d.append(("Length", .number("\(payload.count)")))
        var b: [UInt8] = []
        PDFValue.dict(d).serialize(into: &b)
        b += Array("\nstream\n".utf8) + payload + Array("\nendstream".utf8)
        objects.append((n, 0, b))
    }

    /// 返回完整文件：源字节 + 追加部分。源字节一个不动。
    public func finish(info: PDFValue?) -> [UInt8] {
        var out = file.bytes
        if out.last != 10 { out.append(10) }
        var offsets: [(num: Int, gen: Int, off: Int)] = []
        for o in objects {
            offsets.append((o.num, o.gen, out.count))
            out += Array("\(o.num) \(o.gen) obj\n".utf8) + o.body + Array("\nendobj\n".utf8)
        }
        offsets.sort { $0.num < $1.num }
        var trailerItems: [(String, PDFValue)] = [("Size", .number("\(nextObj)")),
                                                  ("Prev", .number("\(file.lastXRefOffset)"))]
        for k in ["Root", "ID"] {
            if let v = file.trailer[k] { trailerItems.append((k, v)) }
        }
        if let i = info ?? file.trailer["Info"] { trailerItems.append(("Info", i)) }

        func groups() -> [[(num: Int, gen: Int, off: Int)]] {
            var gs: [[(num: Int, gen: Int, off: Int)]] = []
            for e in offsets {
                if let l = gs.last?.last, l.num + 1 == e.num { gs[gs.count - 1].append(e) } else { gs.append([e]) }
            }
            return gs
        }

        if file.usesXRefStream {
            // 源文件用 xref 流时，新节也用 xref 流（不压缩）
            let n = nextObj
            nextObj += 1
            trailerItems[0] = ("Size", .number("\(nextObj)"))
            let xrefOff = out.count
            offsets.append((n, 0, xrefOff))
            var body: [UInt8] = [], index: [PDFValue] = []
            for g in groups() {
                index += [.number("\(g[0].num)"), .number("\(g.count)")]
                for e in g {
                    let o = e.off
                    body += [1, UInt8((o >> 24) & 255), UInt8((o >> 16) & 255), UInt8((o >> 8) & 255), UInt8(o & 255),
                             UInt8((e.gen >> 8) & 255), UInt8(e.gen & 255)]
                }
            }
            var d = trailerItems
            d += [("Type", .name("XRef")), ("W", .array([.number("1"), .number("4"), .number("2")])),
                  ("Index", .array(index)), ("Length", .number("\(body.count)"))]
            var b: [UInt8] = []
            PDFValue.dict(d).serialize(into: &b)
            out += Array("\(n) 0 obj\n".utf8) + b + Array("\nstream\n".utf8) + body + Array("\nendstream\nendobj\n".utf8)
            out += Array("startxref\n\(xrefOff)\n%%EOF\n".utf8)
            return out
        }

        let xrefOff = out.count
        out += Array("xref\n".utf8)
        for g in groups() {
            out += Array("\(g[0].num) \(g.count)\n".utf8)
            for e in g { out += Array(String(format: "%010d %05d n \n", e.off, e.gen).utf8) }
        }
        out += Array("trailer\n".utf8)
        PDFValue.dict(trailerItems).serialize(into: &out)
        out += Array("\nstartxref\n\(xrefOff)\n%%EOF\n".utf8)
        return out
    }
}
#endif
