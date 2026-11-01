#if canImport(CoreGraphics) && canImport(CryptoKit)
import Foundation
import ImageIO
import Vision
import XCTest
@testable import OCRProviders

/// 假服务商：按 maxEdge 读图，超过就报 400；textOnly 时胡编数字。
final class FakeVisionWire: WireClient, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var count = 0, bodies: [Data] = []
    let maxEdge: Int, textOnly: Bool, modelsStatus: Int
    var onImage: (Data) -> String = { _ in "" }

    init(maxEdge: Int = 2048, textOnly: Bool = false, modelsStatus: Int = 200) {
        self.maxEdge = maxEdge; self.textOnly = textOnly; self.modelsStatus = modelsStatus
    }

    func cancelAll() {}

    private func reply(_ text: String) -> HTTPReply {
        let o: [String: Any] = ["choices": [["message": ["content": text]]]]
        return HTTPReply(status: 200, body: try! JSONSerialization.data(withJSONObject: o))
    }

    func perform(_ r: URLRequest) async throws -> HTTPReply {
        lock.lock(); defer { lock.unlock() }
        count += 1
        if r.httpMethod == "GET" {
            return HTTPReply(status: modelsStatus, body: try! JSONSerialization.data(withJSONObject: ["data": [["id": "m1"]]]))
        }
        bodies.append(r.httpBody ?? Data())
        let o = try JSONSerialization.jsonObject(with: r.httpBody!) as! [String: Any]
        if o["response_format"] != nil { return reply("{\"ok\": true}") }
        let c = ((o["messages"] as! [[String: Any]])[0]["content"]) as! [[String: Any]]
        guard let u = (c[0]["image_url"] as? [String: String])?["url"], !textOnly else { return reply("123456") }
        let png = Data(base64Encoded: String(u.dropFirst("data:image/png;base64,".count)))!
        let src = CGImageSourceCreateWithData(png as CFData, nil)!
        let w = CGImageSourceCreateImageAtIndex(src, 0, nil)!.width
        if w > maxEdge { return HTTPReply(status: 400) }
        return reply(onImage(png))
    }

}

final class CapabilityTests: XCTestCase {
    private func prober(_ w: WireClient, net: Bool = true, select: Bool = true) throws -> CapabilityProber {
        let s = ProviderSelection()
        if select { s.select("p") }
        let t = GuardedTransport(wire: w, network: NetworkSwitch(allowed: net), selection: s, gate: UploadGate())
        return CapabilityProber(transport: t, endpoint: try Endpoint("https://api.example.com/v1"), providerID: "p", key: SecretKey("sk"))
    }

    func testSyntheticCodeDiffersEachTime() throws {     // 37
        let a = try XCTUnwrap(SyntheticImage.make(longEdge: 512)), b = try XCTUnwrap(SyntheticImage.make(longEdge: 512))
        XCTAssertEqual(a.code.count, 6)
        XCTAssertFalse(a.code == b.code && a.png == b.png)
        XCTAssertEqual(Array(a.png.prefix(4)), [0x89, 0x50, 0x4E, 0x47])
    }

    func testTextOnlyModelFailsCode() async throws {     // 38
        let w = FakeVisionWire(textOnly: true)
        let p = try await prober(w).probe(model: "m")
        XCTAssertFalse(p.supportsImage)
        XCTAssertNil(p.maxLongEdge)
    }

    func testLadderStopsAtFirstFailure() async throws {  // 39
        let w = FakeVisionWire(maxEdge: 1024)
        w.onImage = { Self.readCode($0) }
        let p = try await prober(w).probe(model: "m")
        XCTAssertEqual(p.maxLongEdge, 1024)
        XCTAssertTrue(p.supportsImage)
        XCTAssertEqual(p.responseFormat, .jsonObject)
        XCTAssertEqual(w.bodies.count, 3 + 1)            // 512、1024、失败的 1792，加 JSON；4096 没发
    }

    /// 用 Vision 真读合成图，顺带确认图是可读的
    private static func readCode(_ png: Data) -> String {
        let src = CGImageSourceCreateWithData(png as CFData, nil)!
        let img = CGImageSourceCreateImageAtIndex(src, 0, nil)!
        let q = VNRecognizeTextRequest()
        try? VNImageRequestHandler(cgImage: img).perform([q])
        return q.results?.compactMap { $0.topCandidates(1).first?.string }.joined() ?? ""
    }

    func testPolicyRefusalPropagates() async throws {
        let w = FakeVisionWire()
        do {
            _ = try await prober(w, net: false).probe(model: "m")
            XCTFail()
        } catch { XCTAssertEqual(error as? TransportError, .refused(.networkOff)) }
        XCTAssertEqual(w.count, 0)
    }

    func testUnselectedProbeZeroCalls() async throws {
        let w = FakeVisionWire()
        do {
            _ = try await prober(w, select: false).probe(model: "m")
            XCTFail()
        } catch { XCTAssertEqual(error as? TransportError, .refused(.providerNotSelected)) }
        let models = await (try prober(w, select: false)).listModels()
        XCTAssertEqual(models, [])
        XCTAssertEqual(w.count, 0)
    }

    func testModelsFailureReturnsEmpty() async throws {  // 40
        let models = await (try prober(FakeVisionWire(modelsStatus: 500))).listModels()
        XCTAssertEqual(models, [])
    }

    func testProfileHasNoKey() throws {                  // 34
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = CapabilityProfile(providerID: "../p", model: "m", probedAt: Date(), supportsImage: true, maxLongEdge: 512, responseFormat: .text)
        try ProfileStore.save(p, in: dir)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["___p--m.json"])
    }

    func testTwoModelsKeepSeparateProfiles() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("prof-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        for m in ["a/b", "c"] {
            try ProfileStore.save(CapabilityProfile(providerID: "p", model: m, probedAt: Date(), supportsImage: false, responseFormat: .text), in: dir)
        }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path).count, 2)
    }

    func testPresetsAreOnlyAList() {
        XCTAssertTrue(ProviderPresets.all.contains { $0.id == "anthropic" })
        let s = ProviderSelection()
        for p in ProviderPresets.all { XCTAssertFalse(s.isSelected(p.id)) }
    }

    func testMemoryStoreRoundTrip() {
        let m = MemorySecretStore()
        m.save("k", for: "p")
        XCTAssertEqual(m.load("p")?.value, "k")
        m.delete("p")
        XCTAssertNil(m.load("p"))
    }
}
#endif
