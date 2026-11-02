#if canImport(CoreML)
import CoreGraphics
import CoreML
import Foundation
import OCRCore

// PP-OCRv6 的 Core ML 推理。流程、参数与 RapidOCR 3.9.2 一致：
//   长边缩到 2000（对齐 32）→ DB 检测 → 透视裁行 → 方向分类 → 识别 → CTC 解码 → text_score 过滤。
//
// 与 OpenCV 不逐位相同的地方（都不影响文字层面）：
//   - findContours 只取外轮廓：minAreaRect 只看凸包，这里直接求连通域的凸包；内孔轮廓不要；
//   - pyclipper 的圆角外扩：矩形圆角外扩后的最小外接矩形就是四边各外扩 d，直接这么算；
//   - 灰度线性插值用浮点，OpenCV 用定点，个别像素差 1。
// 检测：常见尺寸用固定形状模型（才能上 ANE）；其余走可变尺寸模型（CPU/GPU），输入始终是精确尺寸，不补白。
// 识别按行宽分桶，宽出来的部分补 0，这和 RapidOCR 批内对齐到最宽那行的做法相同。

public enum PaddleError: Error, CustomStringConvertible {
    case noModels(String), badImage, badOutput(String)

    public var description: String {
        switch self {
        case .noModels(let s): return "找不到 Core ML 模型: \(s)"
        case .badImage: return "页图不是 8 位灰度"
        case .badOutput(let s): return "模型输出不对: \(s)"
        }
    }
}

struct Gray {
    var w: Int, h: Int
    var px: [UInt8]

    init(w: Int, h: Int, px: [UInt8]) {
        self.w = w; self.h = h; self.px = px
    }

    init(_ img: CGImage) throws {
        w = img.width
        h = img.height
        px = [UInt8](repeating: 0, count: w * h)
        guard let ctx = px.withUnsafeMutableBytes({ b in
            CGContext(data: b.baseAddress, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width,
                      space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
        }) else { throw PaddleError.badImage }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }

    /// cv2.resize INTER_LINEAR：半像素对齐，不抗锯齿。
    func resized(_ dw: Int, _ dh: Int) -> Gray {
        if dw == w, dh == h { return self }
        let sx = Double(w) / Double(dw), sy = Double(h) / Double(dh)
        var xi = [Int](repeating: 0, count: dw), xf = [Float](repeating: 0, count: dw)
        for x in 0..<dw {
            let v = (Double(x) + 0.5) * sx - 0.5
            let f = v.rounded(.down)
            xi[x] = min(max(Int(f), 0), max(0, w - 2))
            xf[x] = v < 0 ? 0 : (Int(f) >= w - 1 ? 1 : Float(v - f))
        }
        var out = [UInt8](repeating: 0, count: dw * dh)
        px.withUnsafeBufferPointer { s in
            out.withUnsafeMutableBufferPointer { d in
                for y in 0..<dh {
                    let v = (Double(y) + 0.5) * sy - 0.5
                    let f = v.rounded(.down)
                    let y0 = min(max(Int(f), 0), max(0, h - 2))
                    let fy: Float = v < 0 ? 0 : (Int(f) >= h - 1 ? 1 : Float(v - f))
                    let r0 = y0 * w, r1 = h > 1 ? (y0 + 1) * w : r0
                    for x in 0..<dw {
                        let a = xi[x], b = w > 1 ? a + 1 : a, t = xf[x]
                        let top = Float(s[r0 + a]) * (1 - t) + Float(s[r0 + b]) * t
                        let bot = Float(s[r1 + a]) * (1 - t) + Float(s[r1 + b]) * t
                        d[y * dw + x] = UInt8(min(255, max(0, (top * (1 - fy) + bot * fy).rounded())))
                    }
                }
            }
        }
        return Gray(w: dw, h: dh, px: out)
    }
}

extension Gray {
    var cgImage: CGImage? {
        guard let prov = CGDataProvider(data: Data(px) as CFData) else { return nil }
        return CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: w,
                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                       provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    /// 顺时针旋转 deg（90/180/270）。
    func rotated(_ deg: Int) -> Gray {
        switch deg {
        case 180: return Gray(w: w, h: h, px: px.reversed())
        case 90:
            var o = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { o[x * h + (h - 1 - y)] = px[y * w + x] } }
            return Gray(w: h, h: w, px: o)
        case 270:
            var o = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h { for x in 0..<w { o[(w - 1 - x) * h + y] = px[y * w + x] } }
            return Gray(w: h, h: w, px: o)
        default: return self
        }
    }
}

/// 转正后的图（顺时针转过 deg）上的框映射回原图。w/h 是原图尺寸。
public func rotateBack(_ l: Line, _ deg: Int, w: Int, h: Int) -> Line {
    var r = l
    let W = Double(w), H = Double(h)
    switch deg {
    case 180: r.x = W - l.x - l.w; r.y = H - l.y - l.h
    case 90: r.x = l.y; r.y = H - l.x - l.w; r.w = l.h; r.h = l.w
    case 270: r.x = W - l.y - l.h; r.y = l.x; r.w = l.h; r.h = l.w
    default: break
    }
    return r
}

// MARK: - 几何

struct P2 { var x: Double, y: Double }

private func cross(_ o: P2, _ a: P2, _ b: P2) -> Double { (a.x - o.x) * (b.y - o.y) - (a.y - o.y) * (b.x - o.x) }

func convexHull(_ pts: [P2]) -> [P2] {
    let s = pts.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    if s.count < 3 { return s }
    var lo: [P2] = [], hi: [P2] = []
    for p in s {
        while lo.count >= 2, cross(lo[lo.count - 2], lo[lo.count - 1], p) <= 0 { lo.removeLast() }
        lo.append(p)
    }
    for p in s.reversed() {
        while hi.count >= 2, cross(hi[hi.count - 2], hi[hi.count - 1], p) <= 0 { hi.removeLast() }
        hi.append(p)
    }
    return Array(lo.dropLast() + hi.dropLast())
}

struct RotRect {
    var cx: Double, cy: Double, w: Double, h: Double
    var ux: Double, uy: Double      // w 方向的单位向量

    var corners: [P2] {
        let vx = -uy, vy = ux
        return [(-1.0, -1.0), (1, -1), (1, 1), (-1, 1)].map { (a, b) in
            P2(x: cx + a * w / 2 * ux + b * h / 2 * vx, y: cy + a * w / 2 * uy + b * h / 2 * vy)
        }
    }
}

/// cv2.minAreaRect：最小外接矩形必有一条边贴凸包的某条边。
func minAreaRect(_ hull: [P2]) -> RotRect? {
    guard hull.count >= 2 else { return nil }
    var best: RotRect?, bestArea = Double.infinity
    for i in hull.indices {
        let a = hull[i], b = hull[(i + 1) % hull.count]
        let dx = b.x - a.x, dy = b.y - a.y, len = (dx * dx + dy * dy).squareRoot()
        if len == 0 { continue }
        let ux = dx / len, uy = dy / len
        var minU = Double.infinity, maxU = -Double.infinity, minV = Double.infinity, maxV = -Double.infinity
        for p in hull {
            let u = p.x * ux + p.y * uy, v = -p.x * uy + p.y * ux
            minU = min(minU, u); maxU = max(maxU, u); minV = min(minV, v); maxV = max(maxV, v)
        }
        let area = (maxU - minU) * (maxV - minV)
        if area < bestArea {
            bestArea = area
            let cu = (minU + maxU) / 2, cv = (minV + maxV) / 2
            best = RotRect(cx: cu * ux - cv * uy, cy: cu * uy + cv * ux, w: maxU - minU, h: maxV - minV, ux: ux, uy: uy)
        }
    }
    return best
}

/// get_mini_boxes 的顶点顺序：按 x 排序后，左两点上者为 0、下者为 3，右两点上者为 1、下者为 2。
func miniBox(_ r: RotRect) -> [P2] {
    let c = r.corners.sorted { $0.x != $1.x ? $0.x < $1.x : $0.y < $1.y }
    let (a, d) = c[1].y > c[0].y ? (c[0], c[1]) : (c[1], c[0])
    let (b, e) = c[3].y > c[2].y ? (c[2], c[3]) : (c[3], c[2])
    return [a, b, e, d]
}

private func dist(_ a: P2, _ b: P2) -> Double { ((a.x - b.x) * (a.x - b.x) + (a.y - b.y) * (a.y - b.y)).squareRoot() }

func solveHomography(_ src: [P2], _ dst: [P2]) -> [Double] {
    // 求 dst → src 的 3×3（h33 = 1），用于反向采样
    var a = [[Double]](repeating: [Double](repeating: 0, count: 9), count: 8)
    for i in 0..<4 {
        let (x, y, u, v) = (dst[i].x, dst[i].y, src[i].x, src[i].y)
        a[2 * i] = [x, y, 1, 0, 0, 0, -x * u, -y * u, u]
        a[2 * i + 1] = [0, 0, 0, x, y, 1, -x * v, -y * v, v]
    }
    for c in 0..<8 {
        var p = c
        for r in c..<8 where abs(a[r][c]) > abs(a[p][c]) { p = r }
        a.swapAt(c, p)
        let d = a[c][c]
        if d == 0 { continue }
        for k in c..<9 { a[c][k] /= d }
        for r in 0..<8 where r != c {
            let f = a[r][c]
            if f != 0 { for k in c..<9 { a[r][k] -= f * a[c][k] } }
        }
    }
    return (0..<8).map { a[$0][8] } + [1]
}

private func cubic(_ t: Double) -> (Double, Double, Double, Double) {
    let A = -0.75, x = t
    let w0 = A * x * (x - 1) * (x - 1)
    let w1 = (A + 2) * x * x * x - (A + 3) * x * x + 1
    let w2 = -(A + 2) * x * x * x + (2 * A + 3) * x * x - A * x
    return (w0, w1, w2, 1 - w0 - w1 - w2)
}

/// get_rotate_crop_image：透视裁行，INTER_CUBIC + BORDER_REPLICATE；高宽比 ≥1.5 时逆时针转 90°。
func cropLine(_ img: Gray, _ pts: [P2]) -> Gray {
    let cw = Int(max(dist(pts[0], pts[1]), dist(pts[2], pts[3])))
    let ch = Int(max(dist(pts[0], pts[3]), dist(pts[1], pts[2])))
    guard cw > 0, ch > 0 else { return Gray(w: 1, h: 1, px: [255]) }
    var out = [UInt8](repeating: 0, count: cw * ch)
    let dst = [P2(x: 0, y: 0), P2(x: Double(cw), y: 0), P2(x: Double(cw), y: Double(ch)), P2(x: 0, y: Double(ch))]
    let m = solveHomography(pts, dst)
    let axis = abs(m[1]) < 1e-9 && abs(m[3]) < 1e-9 && abs(m[6]) < 1e-12 && abs(m[7]) < 1e-12
        && abs(m[0] - 1) < 1e-9 && abs(m[4] - 1) < 1e-9
    if axis {
        let ox = Int(m[2].rounded()), oy = Int(m[5].rounded())
        for y in 0..<ch {
            let sy = min(max(y + oy, 0), img.h - 1)
            for x in 0..<cw { out[y * cw + x] = img.px[sy * img.w + min(max(x + ox, 0), img.w - 1)] }
        }
    } else {
        for y in 0..<ch {
            for x in 0..<cw {
                let fx = Double(x), fy = Double(y)
                let d = m[6] * fx + m[7] * fy + m[8]
                let sx = (m[0] * fx + m[1] * fy + m[2]) / d, sy = (m[3] * fx + m[4] * fy + m[5]) / d
                let ix = Int(sx.rounded(.down)), iy = Int(sy.rounded(.down))
                let wx = cubic(sx - Double(ix)), wy = cubic(sy - Double(iy))
                let xw = [wx.0, wx.1, wx.2, wx.3], yw = [wy.0, wy.1, wy.2, wy.3]
                var v = 0.0
                for j in 0..<4 {
                    let yy = min(max(iy + j - 1, 0), img.h - 1)
                    for i in 0..<4 {
                        let xx = min(max(ix + i - 1, 0), img.w - 1)
                        v += Double(img.px[yy * img.w + xx]) * xw[i] * yw[j]
                    }
                }
                out[y * cw + x] = UInt8(min(255, max(0, v.rounded())))
            }
        }
    }
    let g = Gray(w: cw, h: ch, px: out)
    if Double(ch) / Double(cw) < 1.5 { return g }
    var r = [UInt8](repeating: 0, count: cw * ch)            // np.rot90：逆时针
    for y in 0..<ch {
        for x in 0..<cw { r[(cw - 1 - x) * ch + y] = out[y * cw + x] }
    }
    return Gray(w: ch, h: cw, px: r)
}

/// ClipperOffset 的 JT_ROUND：每个顶点在两条邻边的法线之间走圆弧，坐标四舍五入成整数。
/// arc tolerance 取 pyclipper 默认的 0.25。
func roundOffset(_ poly: [P2], _ d: Double) -> [P2] {
    let n = poly.count
    var area = 0.0
    for i in 0..<n { area += poly[i].x * poly[(i + 1) % n].y - poly[(i + 1) % n].x * poly[i].y }
    let pts = area > 0 ? poly : Array(poly.reversed())       // 统一逆时针（y 向下时视觉上顺时针）
    var normals: [P2] = []
    for i in 0..<n {
        let a = pts[i], b = pts[(i + 1) % n]
        let dx = b.x - a.x, dy = b.y - a.y, l = (dx * dx + dy * dy).squareRoot()
        normals.append(l > 0 ? P2(x: dy / l, y: -dx / l) : P2(x: 0, y: 0))
    }
    let steps = max(.pi / acos(max(-1, 1 - 0.25 / max(d, 0.25))), 4) / (2 * .pi)
    var out: [P2] = []
    for i in 0..<n {
        let p = pts[i], n0 = normals[(i + n - 1) % n], n1 = normals[i]
        var a0 = atan2(n0.y, n0.x), a1 = atan2(n1.y, n1.x)
        if a1 < a0 { a1 += 2 * .pi }
        if a1 - a0 > .pi { swap(&a0, &a1); a1 += 2 * .pi }
        let k = max(1, Int(steps * 2 * .pi * (a1 - a0) / (2 * .pi)))
        for j in 0...k {
            let t = a0 + (a1 - a0) * Double(j) / Double(k)
            out.append(P2(x: (p.x + d * cos(t)).rounded(), y: (p.y + d * sin(t)).rounded()))
        }
    }
    return out
}

// MARK: - DB 后处理

struct DetBox {
    var pts: [P2]        // tl tr br bl，图像坐标（整数）
    var score: Double
}

let dbThresh: Float = 0.3, dbBoxThresh = 0.5, dbUnclip = 1.6, dbMinSize = 3.0

/// 概率图 → 文本框。w/h 是概率图尺寸，destW/destH 是要映射到的图尺寸。
func dbPostprocess(_ pred: UnsafeBufferPointer<Float>, w: Int, h: Int, destW: Int, destH: Int) -> [DetBox] {
    var seg = [UInt8](repeating: 0, count: w * h)
    for i in 0..<(w * h) where pred[i] > dbThresh { seg[i] = 1 }
    // cv2.dilate 2×2，锚点 (1,1)：看本像素和左、上、左上
    var mask = seg
    for y in 0..<h {
        for x in 0..<w where seg[y * w + x] == 0 {
            if (x > 0 && seg[y * w + x - 1] != 0) || (y > 0 && seg[(y - 1) * w + x] != 0)
                || (x > 0 && y > 0 && seg[(y - 1) * w + x - 1] != 0) {
                mask[y * w + x] = 1
            }
        }
    }
    // 8 连通域，每个域只记每行的左右端点（够求凸包）
    var label = [Int32](repeating: 0, count: w * h)
    var next: Int32 = 0
    var stack: [Int] = []
    var boxes: [DetBox] = []
    for start in 0..<(w * h) where mask[start] != 0 && label[start] == 0 {
        next += 1
        label[start] = next
        stack.append(start)
        var rows: [Int: (Int, Int)] = [:]
        while let i = stack.popLast() {
            let x = i % w, y = i / w
            if let r = rows[y] { rows[y] = (min(r.0, x), max(r.1, x)) } else { rows[y] = (x, x) }
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx, ny = y + dy
                    if nx >= 0, nx < w, ny >= 0, ny < h {
                        let k = ny * w + nx
                        if mask[k] != 0, label[k] == 0 {
                            label[k] = next
                            stack.append(k)
                        }
                    }
                }
            }
        }
        var pts: [P2] = []
        for (y, r) in rows {
            pts.append(P2(x: Double(r.0), y: Double(y)))
            pts.append(P2(x: Double(r.1), y: Double(y)))
        }
        guard let rect = minAreaRect(convexHull(pts)), min(rect.w, rect.h) >= dbMinSize else { continue }
        let box = miniBox(rect)

        // box_score_fast：框内概率均值（框顶点截断成整数，边界算在内）
        let xs = box.map(\.x), ys = box.map(\.y)
        let xmin = min(max(Int(xs.min()!.rounded(.down)), 0), w - 1), xmax = min(max(Int(xs.max()!.rounded(.up)), 0), w - 1)
        let ymin = min(max(Int(ys.min()!.rounded(.down)), 0), h - 1), ymax = min(max(Int(ys.max()!.rounded(.up)), 0), h - 1)
        let poly = box.map { P2(x: Double(Int($0.x)), y: Double(Int($0.y))) }
        var sum = 0.0, cnt = 0
        for y in ymin...ymax {
            for x in xmin...xmax {
                let p = P2(x: Double(x), y: Double(y))
                var pos = true, neg = true
                for k in 0..<4 {
                    let c = cross(poly[k], poly[(k + 1) % 4], p)
                    if c < 0 { pos = false }
                    if c > 0 { neg = false }
                }
                if pos || neg {
                    sum += Double(pred[y * w + x])
                    cnt += 1
                }
            }
        }
        let score = cnt > 0 ? sum / Double(cnt) : 0
        if dbBoxThresh > score { continue }

        // unclip：shapely 算距离（用浮点框），pyclipper 外扩（顶点先截断成整数，结果也是整数）
        let d = rect.w * rect.h * dbUnclip / (2 * (rect.w + rect.h))
        guard let big = minAreaRect(convexHull(roundOffset(box.map { P2(x: $0.x.rounded(.towardZero), y: $0.y.rounded(.towardZero)) }, d))),
              min(big.w, big.h) >= dbMinSize + 2 else { continue }
        let ex = miniBox(big).map { p -> P2 in
            P2(x: min(max((p.x / Double(w) * Double(destW)).rounded(), 0), Double(destW)),
               y: min(max((p.y / Double(h) * Double(destH)).rounded(), 0), Double(destH)))
        }
        // order_points_clockwise + clip_det_res
        let byX = ex.sorted { $0.x < $1.x }
        let left = byX[0..<2].sorted { $0.y < $1.y }, right = byX[2..<4].sorted { $0.y < $1.y }
        let ord = [left[0], right[0], right[1], left[1]].map {
            P2(x: min(max($0.x, 0), Double(destW - 1)), y: min(max($0.y, 0), Double(destH - 1)))
        }
        if Int(dist(ord[0], ord[1])) <= 3 || Int(dist(ord[0], ord[3])) <= 3 { continue }
        boxes.append(DetBox(pts: ord, score: score))
    }
    return sortedBoxes(boxes)
}

/// TextDetector.sorted_boxes：按左上 y 稳定排序，相邻 y 差 <10 算一行，行内按 x。
func sortedBoxes(_ b: [DetBox]) -> [DetBox] {
    let s = b.enumerated().sorted { $0.element.pts[0].y != $1.element.pts[0].y ? $0.element.pts[0].y < $1.element.pts[0].y : $0.offset < $1.offset }.map(\.element)
    var line = 0, keyed: [(Int, Double, Int, DetBox)] = []
    for (i, x) in s.enumerated() {
        if i > 0, x.pts[0].y - s[i - 1].pts[0].y >= 10 { line += 1 }
        keyed.append((line, x.pts[0].x, i, x))
    }
    return keyed.sorted { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }.map(\.3)
}

/// 页图 → 8 位灰度像素（给进程内 VLM 用）。
public func grayPixels(_ img: CGImage) throws -> (px: [UInt8], w: Int, h: Int) {
    let g = try Gray(img)
    return (g.px, g.w, g.h)
}

// MARK: - 设备规划

public struct DevicePlan: Encodable, Sendable {
    public var model: String
    public var units: String
    public var ops = 0, ane = 0, gpu = 0, cpu = 0
    public var aneSupported = 0
}

/// MLComputePlan：Core ML 打算把每个算子放在哪。
/// --units 的取值
public func computeUnits(_ label: String) -> MLComputeUnits? {
    ["ane": .cpuAndNeuralEngine, "all": .all, "cpu": .cpuOnly, "gpu": .cpuAndGPU][label]
}

@available(macOS 14.4, *)
public func computePlan(_ compiled: URL, name: String, units: MLComputeUnits, label: String) async throws -> DevicePlan {
    let cfg = MLModelConfiguration()
    cfg.computeUnits = units
    let plan = try await MLComputePlan.load(contentsOf: compiled, configuration: cfg)
    var r = DevicePlan(model: name, units: label)
    guard case .program(let prog) = plan.modelStructure, let fn = prog.functions["main"] else { return r }
    for op in fn.block.operations {
        guard let u = plan.deviceUsage(for: op) else { continue }
        r.ops += 1
        switch u.preferred {
        case .neuralEngine: r.ane += 1
        case .gpu: r.gpu += 1
        default: r.cpu += 1
        }
        if u.supported.contains(where: { if case .neuralEngine = $0 { return true } else { return false } }) { r.aneSupported += 1 }
    }
    return r
}

// MARK: - 引擎

public struct PaddleTiming: Sendable {
    public var det = 0.0, post = 0.0, crop = 0.0, cls = 0.0, rec = 0.0
}

public final class PaddleEngine {
    let dir: URL
    let config: MLModelConfiguration
    var detModels: [(w: Int, h: Int, url: URL, model: MLModel?)] = []
    var flexURL: URL?, flexModel: MLModel?
    var recModels: [(w: Int, url: URL, model: MLModel?)] = []
    var clsModel: MLModel?
    let keys: [String]
    /// 逐行方向分类。默认关：书页的行本来就是正的，分类器却会把正常长行判成 180°，翻过来读出乱码。
    public var useCls = false
    /// 整页方向判定：只有判为倒置/横置的页才翻转重跑
    public var useOrientation = true
    public var orientSample = 3, orientMargin = 0.10, orientMinConf = 0.80
    /// 高宽比超过它的页要分块：长边缩到 2000 后字太小，RapidOCR 在这种页上读出的是乱码
    public var tileAspect = 3.0
    /// 识别批大小（一个宽度桶内）
    public var batchSize = 16
    public var timing = PaddleTiming()
    /// 用了大画布补白的页数。补白会让结果变差（实测逐行一致率 98.1% → 93.4%），要进报告。
    public private(set) var canvasFallbacks = 0
    /// 走可变尺寸检测模型的页数（CPU/GPU，比 ANE 慢）
    public private(set) var flexPages = 0
    public private(set) var tiledPages = 0
    public var flexUnits: MLComputeUnits = .cpuAndGPU
    public private(set) var loadSeconds = 0.0

    public init(directory: URL, units: MLComputeUnits) throws {
        dir = directory
        config = MLModelConfiguration()
        config.computeUnits = units
        let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        // App 包里只有预编译的 .mlmodelc；同名的两种都在时算一个
        let stems = Set(names.filter { $0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc") }.map { ($0 as NSString).deletingPathExtension })
        for stem in stems {
            let parts = stem.split(separator: "-")
            let pkg = stem + ".mlpackage"
            let u = directory.appendingPathComponent(names.contains(pkg) ? pkg : stem + ".mlmodelc")
            if parts[0] == "det", parts[1] == "flex" {
                flexURL = u
            } else if parts[0] == "det" {
                let wh = parts[1].split(separator: "x").compactMap { Int($0) }
                detModels.append((wh[0], wh[1], u, nil))
            } else if parts[0] == "rec", let w = Int(parts[1]) {
                recModels.append((w, u, nil))
            }
        }
        detModels.sort { ($0.h, $0.w) < ($1.h, $1.w) }
        recModels.sort { $0.w < $1.w }
        guard !detModels.isEmpty || flexURL != nil, !recModels.isEmpty else { throw PaddleError.noModels(directory.path) }
        keys = try String(contentsOf: directory.appendingPathComponent("keys.txt"), encoding: .utf8).components(separatedBy: "\n")
    }

    /// 编译结果缓存在 .mlmodelc，避免每次运行重编译。
    public func compiled(_ url: URL) throws -> URL {
        let c = url.deletingPathExtension().appendingPathExtension("mlmodelc")
        if FileManager.default.fileExists(atPath: c.path) { return c }      // App 包内只读，只走这里
        let tmp = try MLModel.compileModel(at: url)
        try? FileManager.default.removeItem(at: c)
        try FileManager.default.moveItem(at: tmp, to: c)
        return c
    }

    /// 模型目录里全部 mlpackage 的编译路径（规划用）。
    public func allCompiled() throws -> [(String, URL)] {
        var names = detModels.map(\.url) + recModels.map(\.url) + (flexURL.map { [$0] } ?? [])
        if let c = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .first(where: { $0.hasPrefix("cls-") && ($0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc")) }) {
            names.append(dir.appendingPathComponent(c))
        }
        return try names.map { ($0.deletingPathExtension().lastPathComponent, try compiled($0)) }
    }

    private func load(_ url: URL) throws -> MLModel {
        let t0 = Date()
        defer { loadSeconds += Date().timeIntervalSince(t0) }
        return try MLModel(contentsOf: compiled(url), configuration: config)
    }

    /// 尺寸正好的固定模型优先；否则可变尺寸模型；都没有才用大画布补白（精度差，要报降级）。
    private func detModel(_ w: Int, _ h: Int) throws -> (MLModel, Int, Int) {
        if let i = detModels.firstIndex(where: { $0.w == w && $0.h == h }) {
            if detModels[i].model == nil { detModels[i].model = try load(detModels[i].url) }
            return (detModels[i].model!, w, h)
        }
        if let u = flexURL {
            if flexModel == nil {
                let t0 = Date()
                let cfg = MLModelConfiguration()
                cfg.computeUnits = flexUnits
                flexModel = try MLModel(contentsOf: compiled(u), configuration: cfg)
                loadSeconds += Date().timeIntervalSince(t0)
            }
            flexPages += 1
            return (flexModel!, w, h)
        }
        guard let i = detModels.indices.filter({ detModels[$0].w >= w && detModels[$0].h >= h })
            .min(by: { detModels[$0].w * detModels[$0].h < detModels[$1].w * detModels[$1].h })
        else { throw PaddleError.noModels("没有能装下 \(w)×\(h) 的检测模型") }
        if detModels[i].model == nil { detModels[i].model = try load(detModels[i].url) }
        return (detModels[i].model!, detModels[i].w, detModels[i].h)
    }

    private func recModel(_ w: Int) throws -> (MLModel, Int) {
        let i = recModels.firstIndex { $0.w >= w } ?? recModels.count - 1
        if recModels[i].model == nil { recModels[i].model = try load(recModels[i].url) }
        return (recModels[i].model!, recModels[i].w)
    }

    private func clsLoaded() throws -> MLModel? {
        if clsModel == nil {
            let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            guard let n = names.first(where: { $0.hasPrefix("cls-") && ($0.hasSuffix(".mlpackage") || $0.hasSuffix(".mlmodelc")) }) else { return nil }
            clsModel = try load(dir.appendingPathComponent(n))
        }
        return clsModel
    }

    private func tensor(_ h: Int, _ w: Int) throws -> MLMultiArray {
        try MLMultiArray(shape: [1, 3, NSNumber(value: h), NSNumber(value: w)], dataType: .float32)
    }

    /// 灰度写进 3 通道：(px/255 - 0.5)/0.5，其余位置填 fill。
    private func fill(_ arr: MLMultiArray, _ g: Gray, canvasW: Int, canvasH: Int, pad: Float) {
        let p = arr.dataPointer.assumingMemoryBound(to: Float.self)
        let n = canvasW * canvasH
        for c in 0..<3 {
            let base = p + c * n
            base.update(repeating: pad, count: n)
            for y in 0..<g.h {
                let row = base + y * canvasW
                for x in 0..<g.w { row[x] = Float(g.px[y * g.w + x]) / 127.5 - 1 }
            }
        }
    }

    /// 按 strides 取成连续的 Float：ANE 返回的多维数组常有行填充，不能当连续内存读。
    private func floats(_ a: MLMultiArray) -> [Float] {
        let shape = a.shape.map(\.intValue), strides = a.strides.map(\.intValue)
        var out = [Float](repeating: 0, count: a.count)
        func walk<T>(_ p: UnsafePointer<T>, _ conv: (T) -> Float) {
            var idx = 0
            func rec(_ d: Int, _ off: Int) {
                if d == shape.count {
                    out[idx] = conv(p[off])
                    idx += 1
                    return
                }
                for i in 0..<shape[d] { rec(d + 1, off + i * strides[d]) }
            }
            rec(0, 0)
        }
        a.withUnsafeBytes { raw in
            switch a.dataType {
            case .float32: walk(raw.bindMemory(to: Float.self).baseAddress!) { $0 }
            case .float16: walk(raw.bindMemory(to: Float16.self).baseAddress!) { Float($0) }
            case .double: walk(raw.bindMemory(to: Double.self).baseAddress!) { Float($0) }
            default: break
            }
        }
        return out
    }

    private func predict(_ m: MLModel, _ x: MLMultiArray) throws -> MLMultiArray {
        let input = try MLDictionaryFeatureProvider(dictionary: ["x": x])
        let out = try m.prediction(from: input)
        guard let name = out.featureNames.first, let v = out.featureValue(for: name)?.multiArrayValue else {
            throw PaddleError.badOutput("没有输出")
        }
        return v
    }

    private struct Prepared {
        var img: Gray
        var ratioW: Double, ratioH: Double, top: Int
    }

    /// resize_image_within_bounds + apply_vertical_padding。
    private func prepare(_ src: Gray) -> Prepared {
        func align(_ v: Double) -> Int { Int((Double(Int(v)) / 32).rounded(.toNearestOrEven)) * 32 }
        var img = src
        var ratioW = 1.0, ratioH = 1.0
        if max(img.w, img.h) > 2000 {
            let r = 2000.0 / Double(max(img.w, img.h))
            let rw = align(Double(img.w) * r), rh = align(Double(img.h) * r)
            let (ow, oh) = (img.w, img.h)
            img = img.resized(rw, rh)
            ratioW = Double(ow) / Double(rw)
            ratioH = Double(oh) / Double(rh)
        }
        if min(img.w, img.h) < 30 {
            let r = 30.0 / Double(min(img.w, img.h))
            let rw = align(Double(img.w) * r), rh = align(Double(img.h) * r)
            let (ow, oh) = (img.w, img.h)
            img = img.resized(rw, rh)
            ratioW = Double(ow) / Double(rw)
            ratioH = Double(oh) / Double(rh)
        }
        var top = 0
        if img.h <= 30 || Double(img.w) / Double(img.h) > 8 {
            let newH = max(Int(Double(img.w) / 8), 30) * 2
            top = abs(newH - img.h) / 2
            var px = [UInt8](repeating: 0, count: img.w * (img.h + 2 * top))
            px.replaceSubrange((top * img.w)..<((top + img.h) * img.w), with: img.px)
            img = Gray(w: img.w, h: img.h + 2 * top, px: px)
        }
        return Prepared(img: img, ratioW: ratioW, ratioH: ratioH, top: top)
    }

    private func detect(_ img: Gray) throws -> [DetBox] {
        var dw = img.w, dh = img.h
        if min(dw, dh) < 736 {                 // DetPreProcess：短边不足 736 放大
            let r = 736.0 / Double(min(dw, dh))
            dw = Int(Double(dw) * r)
            dh = Int(Double(dh) * r)
        }
        dw = Int((Double(dw) / 32).rounded(.toNearestOrEven)) * 32
        dh = Int((Double(dh) / 32).rounded(.toNearestOrEven)) * 32
        let detInput = img.resized(dw, dh)

        var t0 = Date()
        let (dm, cw, ch) = try detModel(dw, dh)
        let x = try tensor(ch, cw)
        fill(x, detInput, canvasW: cw, canvasH: ch, pad: 1)
        let out = try predict(dm, x)
        var prob = floats(out)
        timing.det += Date().timeIntervalSince(t0)

        t0 = Date()
        if cw != dw || ch != dh {           // 画布比页面大：把页面部分抠回来
            canvasFallbacks += 1
            var c = [Float](repeating: 0, count: dw * dh)
            for y in 0..<dh { for k in 0..<dw { c[y * dw + k] = prob[y * cw + k] } }
            prob = c
        }
        let boxes = prob.withUnsafeBufferPointer { dbPostprocess($0, w: dw, h: dh, destW: img.w, destH: img.h) }
        timing.post += Date().timeIntervalSince(t0)
        return boxes
    }

    /// 批量识别。同一宽度桶的行一起送 predictions(fromBatch:)，返回与输入同序的 (文字, 置信度)。
    private func readLines(_ crops: [Gray]) throws -> [(String, Double)] {
        var out = [(String, Double)](repeating: ("", 0), count: crops.count)
        var buckets: [Int: [Int]] = [:]
        for (i, g) in crops.enumerated() {
            let need = Int(48 * max(320.0 / 48, Double(g.w) / Double(g.h)))
            let w = recModels.first { $0.w >= need }?.w ?? recModels.last!.w
            buckets[w, default: []].append(i)
        }
        for w in buckets.keys.sorted() {
            let idx = buckets[w]!
            let (rm, bw) = try recModel(w)
            var start = 0
            while start < idx.count {
                let part = Array(idx[start..<min(start + batchSize, idx.count)])
                start += batchSize
                let inputs: [MLFeatureProvider] = try part.map { i in
                    let g = crops[i]
                    let rw = min(Int((48 * Double(g.w) / Double(g.h)).rounded(.up)), bw)
                    let a = try tensor(48, bw)
                    fill(a, g.resized(max(rw, 1), 48), canvasW: bw, canvasH: 48, pad: 0)
                    return try MLDictionaryFeatureProvider(dictionary: ["x": a])
                }
                let res = try rm.predictions(fromBatch: MLArrayBatchProvider(array: inputs))
                for (k, i) in part.enumerated() {
                    let f = res.features(at: k)
                    guard let n = f.featureNames.first, let v = f.featureValue(for: n)?.multiArrayValue else {
                        throw PaddleError.badOutput("批量输出缺失")
                    }
                    out[i] = decode(v)
                }
            }
        }
        return out
    }

    /// 整页方向。行本身的朝向看框：竖框占多数才考虑 90/270，否则只比 0/180。
    /// 非 0 方向必须比 0 明显好才算，书页绝大多数是正的，不能因为个别行的噪声翻页。
    private func orientation(_ crops: [Gray], _ boxes: [DetBox]) throws -> (deg: Int, conf0: Double, best: Double) {
        // 朝向看检测框：cropLine 已经把竖框转平了，看裁好的图看不出来
        let isTall = boxes.map { dist($0.pts[0], $0.pts[3]) > dist($0.pts[0], $0.pts[1]) }
        let usable = crops.indices.filter { max(crops[$0].w, crops[$0].h) >= 3 * min(crops[$0].w, crops[$0].h) }
        if usable.count < 2 { return (0, 0, 0) }
        let picked = Array(usable.sorted { crops[$0].w > crops[$1].w }.prefix(orientSample))
        let sample = picked.map { crops[$0] }
        let tall = picked.filter { isTall[$0] }.count * 2 > picked.count
        func score(_ deg: Int) throws -> Double {
            let c = try readLines(sample.map { $0.rotated(deg) }).map(\.1)
            return c.reduce(0, +) / Double(c.count)
        }
        let base = try score(0)
        let alt = try score(180)
        if tall {
            // cropLine 已把竖框逆时针转过一次。转完读得好，说明整页要顺时针 270°；倒着才读得好，就是 90°。
            // 两种都读不好时多半是竖排，不动。
            let best = max(base, alt)
            if best < orientMinConf { return (0, base, best) }
            return (base >= alt ? 270 : 90, base, best)
        }
        return alt > base + orientMargin ? (180, base, alt) : (0, base, base)
    }

    /// 一页：返回与 _rapid_normalize 相同形状的行（坐标是原图像素）。
    public func recognize(_ image: CGImage) throws -> [Line] {
        try recognize(try Gray(image)).lines
    }

    public func recognizeOriented(_ image: CGImage) throws -> (lines: [Line], rotation: Int) {
        try recognize(try Gray(image))
    }

    /// 把页图按判定结果转正（给 Vision 用）。
    public func rotatedImage(_ image: CGImage, _ deg: Int) throws -> CGImage {
        guard let c = try Gray(image).rotated(deg).cgImage else { throw PaddleError.badImage }
        return c
    }

    /// 高瘦页切成重叠的块分别识别，每行只算给中心所在的块。只切竖向：横向切会把行切断。
    private func recognize(_ src: Gray) throws -> (lines: [Line], rotation: Int) {
        guard Double(src.h) / Double(src.w) > tileAspect else { return try recognizePage(src) }
        let tile = src.w * 2, overlap = src.w / 4
        var y = 0, out: [Line] = [], k = 0
        while y < src.h {
            let end = min(src.h, y + tile)
            let part = Gray(w: src.w, h: end - y, px: Array(src.px[(y * src.w)..<(end * src.w)]))
            let lo = y == 0 ? 0.0 : Double(y) + Double(overlap) / 2
            let hi = end == src.h ? Double(src.h) : Double(end) - Double(overlap) / 2
            for var l in try recognizePage(part).lines {
                l.y += Double(y)
                let c = l.y + l.h / 2
                if c >= lo, c < hi { out.append(l) }
            }
            k += 1
            if end == src.h { break }
            y = end - overlap
        }
        tiledPages += 1
        Log.shared.debug("tiled", ["tiles": .i(k), "width": .i(src.w), "height": .i(src.h)])
        return (sortReadingOrder(out), 0)
    }

    private func recognizePage(_ src: Gray) throws -> (lines: [Line], rotation: Int) {
        var p = prepare(src)
        var boxes = try detect(p.img)
        if boxes.isEmpty { return ([], 0) }

        var t0 = Date()
        var crops = boxes.map { cropLine(p.img, $0.pts) }
        timing.crop += Date().timeIntervalSince(t0)

        var rotation = 0
        if useOrientation {
            t0 = Date()
            let o = try orientation(crops, boxes)
            timing.cls += Date().timeIntervalSince(t0)
            if o.deg != 0 {
                rotation = o.deg
                Log.shared.debug("orientation", ["rotation": .i(o.deg), "conf0": .d(o.conf0), "best": .d(o.best)])
                p = prepare(src.rotated(o.deg))
                boxes = try detect(p.img)
                if boxes.isEmpty { return ([], rotation) }
                t0 = Date()
                crops = boxes.map { cropLine(p.img, $0.pts) }
                timing.crop += Date().timeIntervalSince(t0)
            }
        }

        // 逐行方向分类（只留作与 RapidOCR 对照，默认关）
        t0 = Date()
        if useCls, let cm = try clsLoaded() {
            for i in crops.indices {
                let g = crops[i]
                let rw = min(Int((48.0 * Double(g.w) / Double(g.h)).rounded(.up)), 192)
                let a = try tensor(48, 192)
                fill(a, g.resized(max(rw, 1), 48), canvasW: 192, canvasH: 48, pad: 0)
                let q = floats(try predict(cm, a))
                if q.count >= 2, q[1] > q[0], q[1] > 0.9 {
                    crops[i] = Gray(w: g.w, h: g.h, px: g.px.reversed())
                }
            }
        }
        timing.cls += Date().timeIntervalSince(t0)

        t0 = Date()
        var lines: [Line] = []
        let read = batchSize > 0 ? try readLines(crops) : try crops.map { try readLines([$0])[0] }
        for i in crops.indices {
            let (text, score) = read[i]
            if pyStrip(text).unicodeScalars.isEmpty || score < 0.5 { continue }
            let xs = boxes[i].pts.map { $0.x * p.ratioW }
            let ys = boxes[i].pts.map { max(0, $0.y - Double(p.top)) * p.ratioH }
            let x0 = xs.min()!, y0 = ys.min()!
            var l = Line(x: pyRound(x0, 1), y: pyRound(y0, 1), w: pyRound(xs.max()! - x0, 1),
                         h: pyRound(ys.max()! - y0, 1), conf: pyRound(score, 4), text: text)
            if rotation != 0 { l = rotateBack(l, rotation, w: src.w, h: src.h) }
            lines.append(l)
        }
        timing.rec += Date().timeIntervalSince(t0)
        return (sortReadingOrder(lines), rotation)
    }

    /// CTC：相邻去重 + 去 blank；置信度取保留下来的字的均值。
    private func decode(_ o: MLMultiArray) -> (String, Double) {
        let T = o.shape[1].intValue, K = o.shape[2].intValue
        let st = o.strides[1].intValue, sk = o.strides[2].intValue
        var idx = [Int](repeating: 0, count: T), val = [Float](repeating: 0, count: T)
        // 输出每行 T×K（K≈1.9 万），不能先拷成 [Float]：直接在缓冲区上取 argmax，并跳过 strides 的行填充
        o.withUnsafeBytes { raw in
            func scan<V: BinaryFloatingPoint>(_ p: UnsafePointer<V>) {
                for t in 0..<T {
                    let base = t * st
                    var bi = 0, bv = p[base]
                    var off = base + sk
                    for k in 1..<K {
                        let v = p[off]
                        if v > bv { bv = v; bi = k }
                        off += sk
                    }
                    idx[t] = bi
                    val[t] = Float(bv)
                }
            }
            switch o.dataType {
            case .float16: scan(raw.bindMemory(to: Float16.self).baseAddress!)
            case .float32: scan(raw.bindMemory(to: Float.self).baseAddress!)
            case .double: scan(raw.bindMemory(to: Double.self).baseAddress!)
            default: break
            }
        }
        var prev = -1, text = "", confs: [Double] = []
        for t in 0..<T {
            let bi = idx[t]
            if bi != 0, bi != prev, bi < keys.count {
                text += keys[bi]
                confs.append((Double(val[t]) * 100_000).rounded() / 100_000)
            }
            prev = bi
        }
        return (text, confs.isEmpty ? 0 : confs.reduce(0, +) / Double(confs.count))
    }
}
#endif
