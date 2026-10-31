import Foundation
import MLX
import MLXFast
import MLXNN

// PaddleOCR-VL-1.6 的进程内推理（MLX）。结构逐层对应 mlx-vlm 的 paddleocr_vl，权重键名相同，
// 所以能直接加载 mlx-vlm 转出的 8bit 量化权重。
//
// 只依赖 mlx-swift：提示词固定是 "OCR:"，token id 写死；解码只要词表，不需要 tokenizer 库。

struct VisionConfig {
    let hidden = 1152, intermediate = 4304, layers = 27, heads = 16, patch = 14, merge = 2
}

struct TextConfig {
    let hidden = 1024, intermediate = 3072, layers = 18, heads = 16, kvHeads = 2, headDim = 128
    let vocab = 103424, rmsEps: Float = 1e-5, ropeTheta: Float = 500000
    let mropeSection = [16, 24, 24]
}

private func rotateHalf(_ x: MLXArray) -> MLXArray {
    let n = x.dim(-1) / 2
    return concatenated([-x[.ellipsis, n...], x[.ellipsis, ..<n]], axis: -1)
}

// MARK: - 视觉

final class VisionAttention: Module {
    @ModuleInfo var qkv: Linear
    @ModuleInfo(key: "out_proj") var outProj: Linear
    let heads: Int, scale: Float

    init(_ dim: Int, _ heads: Int) {
        self.heads = heads
        scale = pow(Float(dim / heads), -0.5)
        _qkv.wrappedValue = Linear(dim, dim * 3, bias: true)
        _outProj.wrappedValue = Linear(dim, dim, bias: true)
    }

    func callAsFunction(_ x: MLXArray, rotary: MLXArray) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        let all = qkv(x).reshaped(b, l, 3, heads, -1).transposed(2, 0, 1, 3, 4)
        var (q, k, v) = (all[0], all[1], all[2])
        let cos1 = tiled(expandedDimensions(MLX.cos(rotary), axis: 1), repetitions: [1, 1, 2])[.newAxis]
        let sin1 = tiled(expandedDimensions(MLX.sin(rotary), axis: 1), repetitions: [1, 1, 2])[.newAxis]
        q = (q * cos1 + rotateHalf(q) * sin1).asType(x.dtype)
        k = (k * cos1 + rotateHalf(k) * sin1).asType(x.dtype)
        let out = MLXFast.scaledDotProductAttention(
            queries: q.transposed(0, 2, 1, 3), keys: k.transposed(0, 2, 1, 3), values: v.transposed(0, 2, 1, 3),
            scale: scale, mask: .none)
        v = out.transposed(0, 2, 1, 3).reshaped(b, l, -1)
        return outProj(v)
    }
}

final class VisionMLP: Module, UnaryLayer {
    @ModuleInfo var fc1: Linear
    @ModuleInfo var fc2: Linear
    let act = GELU(approximation: .precise)

    init(_ dim: Int, _ hidden: Int) {
        _fc1.wrappedValue = Linear(dim, hidden, bias: true)
        _fc2.wrappedValue = Linear(hidden, dim, bias: true)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { fc2(act(fc1(x))) }
}

final class VisionLayer: Module {
    @ModuleInfo(key: "layer_norm1") var norm1: LayerNorm
    @ModuleInfo(key: "layer_norm2") var norm2: LayerNorm
    @ModuleInfo(key: "self_attn") var attn: VisionAttention
    @ModuleInfo var mlp: VisionMLP

    init(_ c: VisionConfig) {
        _norm1.wrappedValue = LayerNorm(dimensions: c.hidden, eps: 1e-6)
        _norm2.wrappedValue = LayerNorm(dimensions: c.hidden, eps: 1e-6)
        _attn.wrappedValue = VisionAttention(c.hidden, c.heads)
        _mlp.wrappedValue = VisionMLP(c.hidden, c.intermediate)
    }

    func callAsFunction(_ x: MLXArray, rotary: MLXArray) -> MLXArray {
        let h = x + attn(norm1(x), rotary: rotary)
        return h + mlp(norm2(h))
    }
}

final class VisionEmbeddings: Module {
    @ModuleInfo(key: "patch_embedding") var patch: Conv2d
    @ModuleInfo(key: "position_embedding") var position: Embedding

    init(_ c: VisionConfig) {
        _patch.wrappedValue = Conv2d(inputChannels: 3, outputChannels: c.hidden, kernelSize: .init(c.patch), stride: .init(c.patch))
        _position.wrappedValue = Embedding(embeddingCount: 729, dimensions: c.hidden)
    }

    /// 位置编码从 27×27 双线性插值到网格大小。
    func positional(_ h: Int, _ w: Int) -> MLXArray {
        let g = position(MLXArray(0..<729)).reshaped(27, 27, -1)
        func axis(_ n: Int) -> ([Int32], [Int32], MLXArray) {
            var f = [Int32](), c = [Int32](), t = [Float]()
            for i in 0..<n {
                let p = n == 1 ? 0 : (Float(i) + 0.5) * 27 / Float(n) - 0.5
                let lo = p.rounded(.down)
                f.append(Int32(min(max(lo, 0), 26)))
                c.append(Int32(min(max(lo + 1, 0), 26)))
                t.append(p - Float(f.last!))
            }
            return (f, c, MLXArray(t))
        }
        let (rf, rc, rw) = axis(h), (cf, cc, cw) = axis(w)
        let top = g[MLXArray(rf)], bottom = g[MLXArray(rc)]
        let ct = MLXArray(cf), cb = MLXArray(cc)
        let w1 = cw[.newAxis, 0..., .newAxis], w0 = 1 - w1
        let r1 = rw[0..., .newAxis, .newAxis], r0 = 1 - r1
        let upper = top[0..., ct] * w0 + top[0..., cb] * w1
        let lower = bottom[0..., ct] * w0 + bottom[0..., cb] * w1
        return (upper * r0 + lower * r1).asType(g.dtype).reshaped(h * w, -1)
    }
}

final class VisionProjector: Module {
    @ModuleInfo(key: "pre_norm") var preNorm: LayerNorm
    @ModuleInfo(key: "linear_1") var linear1: Linear
    @ModuleInfo(key: "linear_2") var linear2: Linear
    let act = GELU()          // Python 这里是 nn.GELU()，默认 approx="none"；MLP 里才是 "precise"
    let merge: Int

    init(_ dim: Int, _ context: Int, _ merge: Int) {
        self.merge = merge
        let hidden = dim * merge * merge
        _preNorm.wrappedValue = LayerNorm(dimensions: dim, eps: 1e-6)
        _linear1.wrappedValue = Linear(hidden, hidden, bias: true)
        _linear2.wrappedValue = Linear(hidden, context, bias: true)
    }

    func callAsFunction(_ x: MLXArray, h: Int, w: Int) -> MLXArray {
        let d = x.dim(-1), hb = h / merge, wb = w / merge
        let y = preNorm(x).reshaped(1, hb, merge, wb, merge, d).transposed(0, 1, 3, 2, 4, 5)
            .reshaped(hb * wb, merge * merge * d)
        return linear2(act(linear1(y)))
    }
}

final class VisionModel: Module {
    @ModuleInfo var embeddings: VisionEmbeddings
    @ModuleInfo var layers: [VisionLayer]
    @ModuleInfo(key: "post_layernorm") var postNorm: LayerNorm
    @ModuleInfo var projector: VisionProjector
    let cfg: VisionConfig

    init(_ c: VisionConfig, context: Int) {
        cfg = c
        _embeddings.wrappedValue = VisionEmbeddings(c)
        _layers.wrappedValue = (0..<c.layers).map { _ in VisionLayer(c) }
        _postNorm.wrappedValue = LayerNorm(dimensions: c.hidden, eps: 1e-6)
        _projector.wrappedValue = VisionProjector(c.hidden, context, c.merge)
    }

    private func rotaryEmbedding(_ h: Int, _ w: Int) -> MLXArray {
        let dim = c36                       // head_dim / 2 = 72 / 2
        let inv = 1.0 / MLX.pow(MLXArray(Float(10000)), MLXArray(stride(from: 0, to: dim, by: 2).map { Float($0) }) / Float(dim))
        let seq = MLXArray((0..<max(h, w)).map { Float($0) })
        let full = outer(seq, inv)
        var hid = [Int32](), wid = [Int32]()
        for y in 0..<h { for x in 0..<w { hid.append(Int32(y)); wid.append(Int32(x)) } }
        let a = full[MLXArray(hid)], b = full[MLXArray(wid)]
        return concatenated([a, b], axis: -1)
    }

    private var c36: Int { cfg.hidden / cfg.heads / 2 }

    /// pixels: (1, H, W, 3)。返回 (合并后的 token 数, 1024)。
    func callAsFunction(_ pixels: MLXArray, h: Int, w: Int) -> MLXArray {
        let x = embeddings.patch(pixels.asType(embeddings.patch.weight.dtype)).reshaped(1, h * w, -1)
        var hidden = x + embeddings.positional(h, w)[.newAxis]
        let rot = rotaryEmbedding(h, w)
        for l in layers { hidden = l(hidden, rotary: rot) }
        return projector(postNorm(hidden), h: h, w: w)
    }
}

// MARK: - 文本

final class KVCache {
    var keys: MLXArray?, values: MLXArray?
    var offset = 0

    func update(_ k: MLXArray, _ v: MLXArray) -> (MLXArray, MLXArray) {
        keys = keys.map { concatenated([$0, k], axis: 2) } ?? k
        values = values.map { concatenated([$0, v], axis: 2) } ?? v
        offset += k.dim(2)
        return (keys!, values!)
    }
}

final class TextAttention: Module {
    @ModuleInfo(key: "q_proj") var qProj: Linear
    @ModuleInfo(key: "k_proj") var kProj: Linear
    @ModuleInfo(key: "v_proj") var vProj: Linear
    @ModuleInfo(key: "o_proj") var oProj: Linear
    let cfg: TextConfig, scale: Float

    init(_ c: TextConfig) {
        cfg = c
        scale = pow(Float(c.headDim), -0.5)
        _qProj.wrappedValue = Linear(c.hidden, c.heads * c.headDim, bias: false)
        _kProj.wrappedValue = Linear(c.hidden, c.kvHeads * c.headDim, bias: false)
        _vProj.wrappedValue = Linear(c.hidden, c.kvHeads * c.headDim, bias: false)
        _oProj.wrappedValue = Linear(c.heads * c.headDim, c.hidden, bias: false)
    }

    func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray, cache: KVCache, causal: Bool) -> MLXArray {
        let (b, l) = (x.dim(0), x.dim(1))
        var q = qProj(x).reshaped(b, l, cfg.heads, cfg.headDim).transposed(0, 2, 1, 3)
        var k = kProj(x).reshaped(b, l, cfg.kvHeads, cfg.headDim).transposed(0, 2, 1, 3)
        let v = vProj(x).reshaped(b, l, cfg.kvHeads, cfg.headDim).transposed(0, 2, 1, 3)
        let c = cos.asType(x.dtype), s = sin.asType(x.dtype)
        q = q * c + rotateHalf(q) * s
        k = k * c + rotateHalf(k) * s
        let (ks, vs) = cache.update(k, v)
        let out = MLXFast.scaledDotProductAttention(queries: q, keys: ks, values: vs, scale: scale,
                                                    mask: causal ? .causal : .none)
        return oProj(out.transposed(0, 2, 1, 3).reshaped(b, l, -1))
    }
}

final class TextMLP: Module {
    @ModuleInfo(key: "gate_proj") var gate: Linear
    @ModuleInfo(key: "up_proj") var up: Linear
    @ModuleInfo(key: "down_proj") var down: Linear

    init(_ d: Int, _ h: Int) {
        _gate.wrappedValue = Linear(d, h, bias: false)
        _up.wrappedValue = Linear(d, h, bias: false)
        _down.wrappedValue = Linear(h, d, bias: false)
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray { down(silu(gate(x)) * up(x)) }
}

final class TextLayer: Module {
    @ModuleInfo(key: "self_attn") var attn: TextAttention
    @ModuleInfo var mlp: TextMLP
    @ModuleInfo(key: "input_layernorm") var inNorm: RMSNorm
    @ModuleInfo(key: "post_attention_layernorm") var postNorm: RMSNorm

    init(_ c: TextConfig) {
        _attn.wrappedValue = TextAttention(c)
        _mlp.wrappedValue = TextMLP(c.hidden, c.intermediate)
        _inNorm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.rmsEps)
        _postNorm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.rmsEps)
    }

    func callAsFunction(_ x: MLXArray, cos: MLXArray, sin: MLXArray, cache: KVCache, causal: Bool) -> MLXArray {
        let h = x + attn(inNorm(x), cos: cos, sin: sin, cache: cache, causal: causal)
        return h + mlp(postNorm(h))
    }
}

final class TextInner: Module {
    @ModuleInfo(key: "embed_tokens") var embed: Embedding
    @ModuleInfo var layers: [TextLayer]
    @ModuleInfo var norm: RMSNorm

    init(_ c: TextConfig) {
        _embed.wrappedValue = Embedding(embeddingCount: c.vocab, dimensions: c.hidden)
        _layers.wrappedValue = (0..<c.layers).map { _ in TextLayer(c) }
        _norm.wrappedValue = RMSNorm(dimensions: c.hidden, eps: c.rmsEps)
    }
}

final class TextModel: Module {
    @ModuleInfo var model: TextInner
    @ModuleInfo(key: "lm_head") var lmHead: Linear

    init(_ c: TextConfig) {
        _model.wrappedValue = TextInner(c)
        _lmHead.wrappedValue = Linear(c.hidden, c.vocab, bias: false)
    }
}

public final class PaddleVLModel: Module {
    @ModuleInfo var visual: VisionModel
    @ModuleInfo(key: "language_model") var language: TextModel
    let vc = VisionConfig(), tc = TextConfig()
    let invFreq: MLXArray, selector: MLXArray

    override init() {
        _visual.wrappedValue = VisionModel(VisionConfig(), context: 1024)
        _language.wrappedValue = TextModel(TextConfig())
        let c = TextConfig()
        invFreq = 1.0 / MLX.pow(MLXArray(c.ropeTheta), MLXArray(stride(from: 0, to: c.headDim, by: 2).map { Float($0) }) / Float(c.headDim))
        var sel = [Int32]()
        for (i, n) in c.mropeSection.enumerated() { sel += [Int32](repeating: Int32(i), count: n) }
        selector = MLXArray(sel)
        super.init()
    }

    /// 分段 MRoPE：positions (3, L)；前 16 个频率用 t，接着 24 个用 h，再 24 个用 w。
    func rope(_ positions: MLXArray) -> (MLXArray, MLXArray) {
        let picked = positions.asType(.float32)[selector]            // (64, L)
        let f = picked.transposed(1, 0) * invFreq
        let emb = concatenated([f, f], axis: -1)
        return (MLX.cos(emb)[.newAxis, .newAxis], MLX.sin(emb)[.newAxis, .newAxis])
    }

    func forward(_ embeds: MLXArray, positions: MLXArray, caches: [KVCache], causal: Bool) -> MLXArray {
        let (c, s) = rope(positions)
        var h = embeds
        for (l, kv) in zip(language.model.layers, caches) { h = l(h, cos: c, sin: s, cache: kv, causal: causal) }
        return language.lmHead(language.model.norm(h))
    }
}

// MARK: - 词表

struct VLTokenizer {
    var pieces: [Int: String] = [:]
    var special = Set<Int>()

    init(_ url: URL) throws {
        let d = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        for (k, v) in (d["model"] as! [String: Any])["vocab"] as! [String: Int] { pieces[v] = k }
        for a in d["added_tokens"] as! [[String: Any]] {
            let id = a["id"] as! Int
            pieces[id] = a["content"] as? String
            if a["special"] as? Bool == true { special.insert(id) }
        }
    }

    func decode(_ ids: [Int]) -> String {
        var bytes = [UInt8]()
        for id in ids where !special.contains(id) {
            guard let p = pieces[id] else { continue }
            if p.count == 6, p.hasPrefix("<0x"), p.hasSuffix(">"), let b = UInt8(p.dropFirst(3).dropLast(), radix: 16) {
                bytes.append(b)
            } else {
                bytes += Array(p.replacingOccurrences(of: "▁", with: " ").utf8)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
}

// MARK: - PIL 重采样（定点，与 Pillow 逐值一致）

enum PILFilter { case bicubic, lanczos }

private func kernel(_ f: PILFilter, _ x: Double) -> Double {
    switch f {
    case .bicubic:
        let a = -0.5, t = abs(x)
        if t < 1 { return ((a + 2) * t - (a + 3)) * t * t + 1 }
        if t < 2 { return (((t - 5) * t + 8) * t - 4) * a }
        return 0
    case .lanczos:
        func sinc(_ v: Double) -> Double { v == 0 ? 1 : Darwin.sin(.pi * v) / (.pi * v) }
        return abs(x) < 3 ? sinc(x) * sinc(x / 3) : 0
    }
}

private func coeffs(_ f: PILFilter, inSize: Int, outSize: Int) -> [(start: Int, w: [Int32])] {
    let support0 = f == .bicubic ? 2.0 : 3.0
    let scale = Double(inSize) / Double(outSize)
    let fs = max(scale, 1)
    let support = support0 * fs
    return (0..<outSize).map { xx in
        let center = (Double(xx) + 0.5) * scale
        let xmin = max(Int(center - support + 0.5), 0)
        let xmax = min(Int(center + support + 0.5), inSize)
        var k = (0..<(xmax - xmin)).map { kernel(f, (Double($0 + xmin) - center + 0.5) / fs) }
        let t = k.reduce(0, +)
        if t != 0 { k = k.map { $0 / t } }
        let one = Double(1 << 22)
        return (xmin, k.map { Int32($0 < 0 ? -0.5 + $0 * one : 0.5 + $0 * one) })
    }
}

/// Image.resize：先横后纵。输入输出都是 8 位灰度。
func pilResize(_ px: [UInt8], w: Int, h: Int, to dw: Int, _ dh: Int, _ f: PILFilter) -> [UInt8] {
    func clip(_ v: Int64) -> UInt8 { UInt8(min(max(v >> 22, 0), 255)) }
    let half: Int64 = 1 << 21
    let cx = coeffs(f, inSize: w, outSize: dw), cy = coeffs(f, inSize: h, outSize: dh)
    var tmp = [UInt8](repeating: 0, count: dw * h)
    for y in 0..<h {
        for x in 0..<dw {
            let (s, k) = cx[x]
            var ss = half
            for (i, c) in k.enumerated() { ss += Int64(px[y * w + s + i]) * Int64(c) }
            tmp[y * dw + x] = clip(ss)
        }
    }
    var out = [UInt8](repeating: 0, count: dw * dh)
    for y in 0..<dh {
        let (s, k) = cy[y]
        for x in 0..<dw {
            var ss = half
            for (i, c) in k.enumerated() { ss += Int64(tmp[(s + i) * dw + x]) * Int64(c) }
            out[y * dw + x] = clip(ss)
        }
    }
    return out
}

func smartResize(_ height: Int, _ width: Int, factor: Int = 28, minPixels: Int = 112896, maxPixels: Int = 4064256) -> (Int, Int) {
    var (h, w) = (Double(height), Double(width))
    let fa = Double(factor)
    if h < fa { w = (w * fa / h).rounded(.toNearestOrEven); h = fa }
    if w < fa { h = (h * fa / w).rounded(.toNearestOrEven); w = fa }
    var hb = (h / fa).rounded(.toNearestOrEven) * fa, wb = (w / fa).rounded(.toNearestOrEven) * fa
    if hb * wb > Double(maxPixels) {
        let beta = (h * w / Double(maxPixels)).squareRoot()
        hb = (h / beta / fa).rounded(.down) * fa
        wb = (w / beta / fa).rounded(.down) * fa
    } else if hb * wb < Double(minPixels) {
        let beta = (Double(minPixels) / (h * w)).squareRoot()
        hb = (h * beta / fa).rounded(.up) * fa
        wb = (w * beta / fa).rounded(.up) * fa
    }
    return (Int(hb), Int(wb))
}

// MARK: - 引擎

public enum VLError: Error, CustomStringConvertible {
    case noModel(String)

    public var description: String {
        switch self {
        case .noModel(let s): return "找不到 PaddleOCR-VL 模型: \(s)"
        }
    }
}

public final class PaddleVL {
    let model: PaddleVLModel
    let tok: VLTokenizer
    public let loadSeconds: Double
    public var maxTokens = 4096, maxSide = 1792
    /// <|begin_of_sentence|>User: <|IMAGE_START|>
    let pre: [Int32] = [100273, 2969, 93963, 93919, 101305]
    /// <|IMAGE_END|>OCR:\nAssistant:\n
    let post: [Int32] = [101306, 93972, 2497, 93963, 23, 92267, 93963, 23]
    let eos = 2

    public init(directory: URL) throws {
        let t0 = Date()
        let st = directory.appendingPathComponent("model.safetensors")
        guard FileManager.default.fileExists(atPath: st.path) else { throw VLError.noModel(directory.path) }
        tok = try VLTokenizer(directory.appendingPathComponent("tokenizer.json"))
        let weights = try loadArrays(url: st)
        let cfg = try JSONSerialization.jsonObject(with: Data(contentsOf: directory.appendingPathComponent("config.json"))) as! [String: Any]
        model = PaddleVLModel()
        if let q = cfg["quantization"] as? [String: Any], let g = q["group_size"] as? Int, let b = q["bits"] as? Int {
            quantize(model: model, groupSize: g, bits: b, mode: .affine, filter: { path, _ in weights["\(path).scales"] != nil })
        }
        try model.update(parameters: ModuleParameters.unflattened(weights), verify: [.noUnusedKeys])
        eval(model)
        loadSeconds = Date().timeIntervalSince(t0)
    }

    /// 一页灰度图 → 文字。px 是 w×h 的 8 位灰度。
    public func read(_ px0: [UInt8], w w0: Int, h h0: Int) -> (text: String, tokens: Int) {
        var (px, w, h) = (px0, w0, h0)
        if max(w, h) > maxSide {                 // 与 P1 的 png_bytes 相同：LANCZOS 缩到长边 1792
            let k = Double(maxSide) / Double(max(w, h))
            let (nw, nh) = (max(1, Int((Double(w) * k).rounded(.toNearestOrEven))), max(1, Int((Double(h) * k).rounded(.toNearestOrEven))))
            px = pilResize(px, w: w, h: h, to: nw, nh, .lanczos)
            (w, h) = (nw, nh)
        }
        let (rh, rw) = smartResize(h, w)
        let img = pilResize(px, w: w, h: h, to: rw, rh, .bicubic)
        let arr = (MLXArray(img, [rh, rw]).asType(.float32) / 255 - 0.5) / 0.5
        let pixels = stacked([arr, arr, arr], axis: -1)[.newAxis]
        let gh = rh / 14, gw = rw / 14
        let features = model.visual(pixels, h: gh, w: gw)
        eval(features)

        let mh = gh / 2, mw = gw / 2, n = mh * mw
        let embed = model.language.model.embed
        let a = embed(MLXArray(pre)[.newAxis]), c = embed(MLXArray(post)[.newAxis])
        let embeds = concatenated([a, features[.newAxis].asType(a.dtype), c], axis: 1)

        // get_rope_index：文字位置顺排，图像按 (t, h, w) 三轴
        var ts = [Int32](), hs = [Int32](), ws = [Int32]()
        for i in 0..<pre.count { ts.append(Int32(i)); hs.append(Int32(i)); ws.append(Int32(i)) }
        let base = Int32(pre.count)
        for y in 0..<mh { for x in 0..<mw { ts.append(base); hs.append(base + Int32(y)); ws.append(base + Int32(x)) } }
        let next = base + Int32(max(mh, mw))
        for i in 0..<post.count {
            let v = next + Int32(i)
            ts.append(v); hs.append(v); ws.append(v)
        }
        let seqLen = pre.count + n + post.count
        let delta = Int(next) + post.count - seqLen
        let positions = stacked([MLXArray(ts), MLXArray(hs), MLXArray(ws)], axis: 0)

        let caches = model.language.model.layers.map { _ in KVCache() }
        var logits = model.forward(embeds, positions: positions, caches: caches, causal: true)
        var out = [Int]()
        for step in 0..<maxTokens {
            let id = argMax(logits[0, -1], axis: -1).item(Int.self)
            if id == eos { break }
            out.append(id)
            let p = Int32(seqLen + step + delta)
            let tokenEmbed = embed(MLXArray([Int32(id)])[.newAxis])
            logits = model.forward(tokenEmbed, positions: MLXArray([p, p, p]).reshaped(3, 1), caches: caches, causal: false)
            eval(logits)
            for kv in caches { if let k = kv.keys, let v = kv.values { eval(k, v) } }
        }
        return (tok.decode(out), out.count)
    }
}
