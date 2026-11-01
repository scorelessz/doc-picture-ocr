#if canImport(CoreGraphics) && canImport(CryptoKit)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import OCRCore

// 能力探测。「测试连接」由用户点击触发，只发程序自己画的合成图，不碰用户文件。

extension SyntheticImage {
    /// 白底黑字，一串随机码。只支持文本的模型靠编造蒙不对。
    public static func make(longEdge: Int) -> SyntheticImage? {
        let code = (0..<6).map { _ in String(Int.random(in: 0...9)) }.joined()
        let w = longEdge, h = longEdge * 3 / 4
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(gray: 0, alpha: 1)
        let attr = NSAttributedString(string: code, attributes: [
            kCTFontAttributeName as NSAttributedString.Key: CTFontCreateWithName("Helvetica" as CFString, CGFloat(longEdge) / 6, nil),
            kCTForegroundColorFromContextAttributeName as NSAttributedString.Key: true])
        ctx.textPosition = CGPoint(x: CGFloat(longEdge) / 8, y: CGFloat(h) / 2)
        CTLineDraw(CTLineCreateWithAttributedString(attr), ctx)
        guard let img = ctx.makeImage(), let out = CFDataCreateMutable(nil, 0),
              let dest = CGImageDestinationCreateWithData(out, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, img, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return SyntheticImage(png: out as Data, code: code)
    }
}

public enum ResponseFormat: String, Sendable, Codable {
    case text, jsonObject
}

public struct CapabilityProfile: Sendable, Codable, Equatable {
    public var providerID: String, model: String
    public var probedAt: Date
    public var supportsImage: Bool
    public var maxLongEdge: Int?
    public var responseFormat: ResponseFormat
    public var pricePerMTokens: String?
}

public struct CapabilityProber: Sendable {
    public static let ladder = [512, 1024, 1792, 2048, 4096]
    static let rungRetries = 1
    /// 这里判的是「收到图了吗」，不是读得准不准：好模型也偶尔读错或漏一位。
    /// 6 位随机数字里只差 2 个编辑以内，靠猜基本碰不上。
    static let maxEdits = 2

    static func sawImage(_ digits: String, code: String) -> Bool {
        if digits.contains(code) { return true }     // 有的模型把数字重复几遍
        let a = Array(digits), b = Array(code)
        var prev = Array(0...b.count)
        for (i, x) in a.enumerated() {
            var cur = [i + 1] + [Int](repeating: 0, count: b.count)
            for (j, y) in b.enumerated() { cur[j + 1] = min(prev[j] + (x == y ? 0 : 1), prev[j + 1] + 1, cur[j] + 1) }
            prev = cur
        }
        return prev[b.count] <= maxEdits
    }

    let transport: HTTPTransport, endpoint: Endpoint, providerID: String, key: SecretKey?

    public init(transport: HTTPTransport, endpoint: Endpoint, providerID: String, key: SecretKey?) {
        self.transport = transport; self.endpoint = endpoint; self.providerID = providerID; self.key = key
    }

    /// 拉不到列表返回空，调用方允许手填
    public func listModels() async -> [String] {
        guard let r = try? await transport.send(OutboundRequest(endpoint: endpoint, providerID: providerID, path: "models", payload: .metadata, key: key)),
              r.status == 200, let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let d = o["data"] as? [[String: Any]] else { return [] }
        return d.compactMap { $0["id"] as? String }
    }

    private func chat(_ p: ProbeRequest) async throws -> String? {
        let r = try await transport.send(OutboundRequest(endpoint: endpoint, providerID: providerID, path: "chat/completions", payload: .probe(p), key: key))
        guard r.status == 200, let o = try? JSONSerialization.jsonObject(with: r.body) as? [String: Any],
              let c = o["choices"] as? [[String: Any]], let m = c.first?["message"] as? [String: Any] else { return nil }
        return m["content"] as? String
    }

    /// 策略拒绝照常抛出；服务商返回错误只算这一级不通过，到此为止。
    public func probe(model: String) async throws -> CapabilityProfile {
        var best: Int?
        rungs: for edge in Self.ladder {
            for _ in 0...Self.rungRetries {
                guard let img = SyntheticImage.make(longEdge: edge) else { break rungs }
                let reply = try await chat(ProbeRequest(model: model, prompt: "读出图中的 6 位数字，只回答这 6 位数字。", image: img))
                let digits = (reply ?? "").filter { $0.isASCII && $0.isNumber }    // 有的模型回答里夹中文数字
                Log.shared.debug("probe_rung", ["edge": .i(edge), "want": .s(img.code), "digits": .s(digits), "reply_chars": .i(reply?.count ?? -1)])
                if Self.sawImage(digits, code: img.code) {
                    best = edge
                    continue rungs
                }
            }
            break
        }
        let j = try await chat(ProbeRequest(model: model, prompt: "用 JSON 回答：{\"ok\": true}", image: nil, wantJSON: true))
        let isJSON = j.flatMap { $0.data(using: .utf8) }.flatMap { try? JSONSerialization.jsonObject(with: $0) } != nil
        let p = CapabilityProfile(providerID: providerID, model: model, probedAt: Date(), supportsImage: best != nil,
                                  maxLongEdge: best, responseFormat: isJSON ? .jsonObject : .text, pricePerMTokens: nil)
        Log.shared.info("probe_result", ["host": .s(endpoint.host), "model": .s(model), "supports_image": .b(p.supportsImage),
                                         "max_long_edge": best.map { .i($0) } ?? .null, "response_format": .s(p.responseFormat.rawValue)])
        return p
    }
}

public enum ProfileStore {
    /// <Application Support>/DocOCR/providers
    public static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("DocOCR/providers", isDirectory: true)
    }

    static func safeName(_ id: String) -> String { String(id.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "_" }) }

    /// 每个服务商的每个模型一份
    public static func save(_ p: CapabilityProfile, in dir: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(p).write(to: dir.appendingPathComponent(safeName(p.providerID) + "--" + safeName(p.model) + ".json"), options: .atomic)
    }
}
#endif
