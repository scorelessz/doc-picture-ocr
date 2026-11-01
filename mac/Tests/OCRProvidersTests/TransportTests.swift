#if canImport(CryptoKit)
import Foundation
import XCTest
@testable import OCRProviders

/// 计数的假线路：这里的 count 就是「网络层调用数」
final class MockWire: WireClient, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [URLRequest] = []
    private var replies: [HTTPReply]
    private(set) var cancelled = 0

    init(_ replies: [HTTPReply] = []) { self.replies = replies }

    var count: Int { lock.lock(); defer { lock.unlock() }; return calls.count }
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return calls }

    func perform(_ r: URLRequest) async throws -> HTTPReply {
        lock.lock(); defer { lock.unlock() }
        calls.append(r)
        return replies.isEmpty ? HTTPReply(status: 200) : replies.removeFirst()
    }

    func cancelAll() { lock.lock(); cancelled += 1; lock.unlock() }
}

private func item(_ id: String, _ bytes: Int = 10) -> UploadItem { UploadItem(id: id, sourceFile: "a.pdf", page: 1, bytes: bytes) }

private func manifest(host: String = "api.example.com", model: String = "m", items: [UploadItem]? = nil, limit: Int? = nil) -> UploadManifest {
    UploadManifest(providerID: "p", providerName: "P", host: host, model: model, items: items ?? [item("1"), item("2")],
                   estimatedRequests: 2, byteLimit: limit)
}

final class EndpointTests: XCTestCase {
    func testPlainHTTPRemoteRejected() {                // 19
        XCTAssertThrowsError(try Endpoint("http://api.example.com/v1"))
        XCTAssertNoThrow(try Endpoint("http://127.0.0.1:8080/v1"))
    }

    func testLookalikesAreNotLoopback() throws {        // 20
        for h in ["127.0.0.1.evil.com", "localhost.evil.com", "evil.com", "127.0.0.1.nip.io", "0177.0.0.1", "2130706433", "127.1"] {
            XCTAssertFalse(try Endpoint("https://\(h)/").isLoopback, h)
        }
        XCTAssertFalse(Endpoint.loopback("127.0.0.256"))
    }

    func testTrueLoopback() throws {
        for u in ["http://localhost:1/v1", "http://127.0.0.1/", "http://127.9.8.7/", "http://[::1]:8/", "http://LOCALHOST/"] {
            XCTAssertTrue(try Endpoint(u).isLoopback, u)
        }
    }

    func testLANIsNotLoopback() throws {                // 21
        XCTAssertFalse(try Endpoint("https://192.168.1.2/").isLoopback)
        XCTAssertFalse(try Endpoint("https://mymac.local/").isLoopback)
        XCTAssertThrowsError(try Endpoint("http://192.168.1.2/"))
    }

    func testCredentialsRejected() {
        XCTAssertThrowsError(try Endpoint("https://u:p@api.example.com/"))
    }

    func testPathCannotChangeHost() throws {
        let e = try Endpoint("https://api.example.com/v1")
        XCTAssertEqual(try e.url(path: "//evil.com/x").host, "api.example.com")
        XCTAssertEqual(try e.url(path: "chat/completions").absoluteString, "https://api.example.com/v1/chat/completions")
    }
}

final class TransportTests: XCTestCase {
    let remote = try! Endpoint("https://api.example.com/v1")

    private func setup(net: Bool = true, select: Bool = true, replies: [HTTPReply] = []) -> (MockWire, GuardedTransport, UploadGate, NetworkSwitch) {
        let w = MockWire(replies), n = NetworkSwitch(allowed: net), s = ProviderSelection(), g = UploadGate()
        if select { s.select("p") }
        return (w, GuardedTransport(wire: w, network: n, selection: s, gate: g), g, n)
    }

    private func assertRefused(_ t: GuardedTransport, _ r: OutboundRequest, _ why: Refusal, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await t.send(r)
            XCTFail("应被拒绝", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? TransportError, .refused(why), file: file, line: line)
        }
    }

    private func ticket(_ g: UploadGate, _ m: UploadManifest? = nil) async throws -> UploadTicket {
        await g.request(m ?? manifest())
        return try await g.confirm(checkbox: true, scope: .once)
    }

    // MARK: 总开关

    func testDefaultSwitchIsOff() { XCTAssertFalse(NetworkSwitch().allowed) }

    func testNetworkOffRefusesEveryRemotePayload() async throws {
        let (w, t, g, n) = setup(net: false)
        n.set(allowed: true)
        let tk = try await ticket(g)
        n.set(allowed: false)
        let ps: [Payload] = [.metadata, .probe(ProbeRequest(model: "m", prompt: "x", image: nil)),
                             .userData(body: Data(count: 1), ticket: tk, itemID: "1")]
        for p in ps {
            await assertRefused(t, OutboundRequest(endpoint: remote, providerID: "p", path: "models", payload: p), .networkOff)
        }
        XCTAssertEqual(w.count, 0)
    }

    func testNetworkOffStillAllowsLoopback() async throws {
        let (w, t, _, _) = setup(net: false, select: false)
        let e = try Endpoint("http://127.0.0.1:8080/v1")
        _ = try await t.send(OutboundRequest(endpoint: e, providerID: "local", path: "chat", payload: .loopback(body: Data())))
        _ = try await t.send(OutboundRequest(endpoint: e, providerID: "local", path: "models", payload: .metadata))
        XCTAssertEqual(w.count, 2)
    }

    func testTurningOffCancelsInFlight() {
        let (w, _, _, n) = setup()
        n.set(allowed: false)
        XCTAssertEqual(w.cancelled, 1)
    }

    // MARK: 服务商选中

    func testUnselectedProviderWithKeyZeroCalls() async {
        let (w, t, _, _) = setup(select: false)
        let ps: [Payload] = [.metadata, .probe(ProbeRequest(model: "m", prompt: "x", image: nil))]
        for p in ps {
            await assertRefused(t, OutboundRequest(endpoint: remote, providerID: "p", path: "x", payload: p, key: SecretKey("sk-test")), .providerNotSelected)
        }
        XCTAssertEqual(w.count, 0)
    }

    func testDeselectTakesEffect() async {
        let w = MockWire(), s = ProviderSelection(), t = GuardedTransport(wire: w, network: NetworkSwitch(allowed: true), selection: s, gate: UploadGate())
        s.select("p")
        s.deselect("p")
        await assertRefused(t, OutboundRequest(endpoint: remote, providerID: "p", path: "x", payload: .metadata), .providerNotSelected)
        XCTAssertEqual(w.count, 0)
    }

    // MARK: 负载与地址

    func testLoopbackPayloadToRemoteRefused() async {    // 22
        let (w, t, _, _) = setup()
        await assertRefused(t, OutboundRequest(endpoint: remote, providerID: "p", path: "x", payload: .loopback(body: Data())), .loopbackPayloadToRemote)
        XCTAssertEqual(w.count, 0)
    }

    func testUserDataToLoopbackRefused() async throws {
        let (w, t, g, _) = setup()
        let tk = try await ticket(g)
        let e = try Endpoint("http://127.0.0.1/")
        await assertRefused(t, OutboundRequest(endpoint: e, providerID: "p", path: "x", payload: .userData(body: Data(), ticket: tk, itemID: "1")), .userDataToLoopback)
        XCTAssertEqual(w.count, 0)
    }

    func testProbeBodyContainsOnlySyntheticImage() throws {
        let s = SyntheticImage(png: Data([1, 2, 3]), code: "123456")
        let o = try JSONSerialization.jsonObject(with: ProbeRequest(model: "m", prompt: "read", image: s).body) as! [String: Any]
        let c = ((o["messages"] as! [[String: Any]])[0]["content"]) as! [[String: Any]]
        XCTAssertEqual(c.count, 2)
        XCTAssertEqual((c[0]["image_url"] as! [String: String])["url"], "data:image/png;base64,AQID")
    }

    // MARK: 票据

    private func upload(_ tk: UploadTicket, _ id: String = "1", bytes: Int = 10, ep: Endpoint? = nil) -> OutboundRequest {
        OutboundRequest(endpoint: ep ?? remote, providerID: "p", path: "chat", payload: .userData(body: Data(count: bytes), ticket: tk, itemID: id))
    }

    private func assertGate(_ t: GuardedTransport, _ r: OutboundRequest, _ e: GateError, file: StaticString = #filePath, line: UInt = #line) async {
        do {
            _ = try await t.send(r)
            XCTFail("应被拒绝", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? GateError, e, file: file, line: line)
        }
    }

    func testConfirmedTicketSends() async throws {
        let (w, t, g, _) = setup()
        _ = try await t.send(upload(try await ticket(g)))
        XCTAssertEqual(w.count, 1)
    }

    func testHostMismatchRefused() async throws {        // 9
        let (w, t, g, _) = setup()
        let tk = try await ticket(g)
        await assertGate(t, upload(tk, ep: try Endpoint("https://other.example.com/")), .hostMismatch)
        XCTAssertEqual(w.count, 0)
    }

    func testItemNotInManifestRefused() async throws {   // 10
        let (w, t, g, _) = setup()
        await assertGate(t, upload(try await ticket(g), "99"), .itemNotInManifest)
        XCTAssertEqual(w.count, 0)
    }

    func testBodyLargerThanItemRefused() async throws {
        let (w, t, g, _) = setup()
        await assertGate(t, upload(try await ticket(g), bytes: 11), .itemTooLarge)
        XCTAssertEqual(w.count, 0)
    }

    func testByteLimitRevokes() async throws {           // 11, 25
        let (w, t, g, _) = setup()
        let tk = try await ticket(g)
        for id in ["1", "2"] { _ = try await t.send(upload(tk, id)) }
        await assertGate(t, upload(tk, "1"), .byteLimitExceeded)    // 重试字节计入累计
        XCTAssertEqual(w.count, 2)
        guard case .revoked = await g.state else { return XCTFail("应转 revoked") }
        await assertGate(t, upload(tk, "2", bytes: 1), .ticketInvalid)
    }

    func testFinishInvalidatesTicket() async throws {    // 12
        let (w, t, g, _) = setup()
        let tk = try await ticket(g)
        await g.finish()
        await assertGate(t, upload(tk), .ticketInvalid)
        XCTAssertEqual(w.count, 0)
    }

    func testNewManifestInvalidatesOldTicket() async throws {   // 13, 14
        let (w, t, g, _) = setup()
        let tk = try await ticket(g)
        await g.request(manifest(items: [item("3")]))
        await assertGate(t, upload(tk), .ticketInvalid)
        XCTAssertEqual(w.count, 0)
    }

    func testTicketBoundToProvider() async throws {
        let (w, t, g, _) = setup()
        let s = ProviderSelection()
        s.select("q")
        let t2 = GuardedTransport(wire: w, network: NetworkSwitch(allowed: true), selection: s, gate: g)
        let tk = try await ticket(g)
        await assertGate(t2, OutboundRequest(endpoint: remote, providerID: "q", path: "c", payload: .userData(body: Data(), ticket: tk, itemID: "1")), .ticketInvalid)
        _ = t
        XCTAssertEqual(w.count, 0)
    }

    // MARK: 闸门

    func testAwaitingConfirmCannotIssue() async {        // 2, 3
        let g = UploadGate()
        await g.request(manifest())
        do {
            _ = try await g.confirm(checkbox: false, scope: .once)
            XCTFail()
        } catch { XCTAssertEqual(error as? GateError, .checkboxNotTicked) }
        guard case .awaitingConfirm = await g.state else { return XCTFail("应留在 awaitingConfirm") }
    }

    func testDeclineIsTerminal() async {                 // 4, 5
        let g = UploadGate()
        await g.request(manifest())
        await g.decline()
        let st = await g.state
        XCTAssertEqual(st, .declined)
        do {
            _ = try await g.confirm(checkbox: true, scope: .once)
            XCTFail()
        } catch { XCTAssertEqual(error as? GateError, .notAwaiting) }
    }

    func testConfirmWithoutRequestFails() async {
        do {
            _ = try await UploadGate().confirm(checkbox: true, scope: .once)
            XCTFail()
        } catch { XCTAssertEqual(error as? GateError, .notAwaiting) }
    }

    func testDigestConfirm() async throws {
        let g = UploadGate(), m = manifest()
        await g.request(m)
        do {
            _ = try await g.confirm(manifestSHA256: manifest(model: "other").sha256)
            XCTFail()
        } catch { XCTAssertEqual(error as? GateError, .digestMismatch) }
        _ = try await g.confirm(manifestSHA256: m.sha256)
    }

    func testBatchReuseAndHostChangeReasks() async throws {   // 15
        let g = UploadGate()
        await g.request(manifest())
        _ = try await g.confirm(checkbox: true, scope: .batch(UUID()))
        guard case .confirmed = await g.request(manifest(items: [item("3")])) else { return XCTFail("同批次同 host 应直接发票") }
        guard case .awaitingConfirm = await g.request(manifest(host: "b.example.com")) else { return XCTFail("换 host 要重问") }
    }

    func testBatchModelChangeReasks() async throws {
        let g = UploadGate()
        await g.request(manifest())
        _ = try await g.confirm(checkbox: true, scope: .batch(UUID()))
        guard case .awaitingConfirm = await g.request(manifest(model: "other")) else { return XCTFail("换模型要重问") }
    }

    func testOnceDoesNotCarryToNextFile() async throws {
        let g = UploadGate()
        await g.request(manifest())
        _ = try await g.confirm(checkbox: true, scope: .once)
        guard case .awaitingConfirm = await g.request(manifest(items: [item("3")])) else { return XCTFail("一次性不能带到下一个文件") }
    }

    func testFreshGateHasNoState() async {               // 16
        let st = await UploadGate().state
        XCTAssertEqual(st, .idle)
    }

    // MARK: 重定向

    func testCrossHostRedirectBlocked() async throws {   // 17
        let (w, t, g, _) = setup(replies: [HTTPReply(status: 302, location: "https://evil.com/x")])
        await assertRefused(t, upload(try await ticket(g)), .redirectBlocked)
        XCTAssertEqual(w.count, 1)
    }

    func testSameHostRedirectRechecksTicket() async throws {   // 18
        let (w, t, g, _) = setup(replies: [HTTPReply(status: 307, location: "/v2/chat")])
        let tk = try await ticket(g, manifest(items: [item("1")]))      // 重发要再算一次字节，超上限
        await assertGate(t, upload(tk), .byteLimitExceeded)
        XCTAssertEqual(w.count, 1)
    }

    func testSameHostRedirectFollowed() async throws {
        let (w, t, _, _) = setup(replies: [HTTPReply(status: 302, location: "/v2/models"), HTTPReply(status: 200)])
        let r = try await t.send(OutboundRequest(endpoint: remote, providerID: "p", path: "models", payload: .metadata))
        XCTAssertEqual(r.status, 200)
        XCTAssertEqual(w.requests.last?.url?.absoluteString, "https://api.example.com/v2/models")
    }

    func testHTTPSDowngradeRedirectBlocked() async {
        let (w, t, _, _) = setup(replies: [HTTPReply(status: 302, location: "http://api.example.com/x")])
        await assertRefused(t, OutboundRequest(endpoint: remote, providerID: "p", path: "models", payload: .metadata), .redirectBlocked)
        XCTAssertEqual(w.count, 1)
    }

    func testRedirectLoopStops() async {
        let (w, t, _, _) = setup(replies: (0..<9).map { _ in HTTPReply(status: 302, location: "/a") })
        await assertRefused(t, OutboundRequest(endpoint: remote, providerID: "p", path: "models", payload: .metadata), .tooManyRedirects)
        XCTAssertEqual(w.count, GuardedTransport.maxRedirects + 1)
    }

    // MARK: 失败不换家、会话配置、Key

    func testFailureMakesSingleWireCall() async throws {  // 24 的传输层部分
        let (w, t, g, _) = setup(replies: [HTTPReply(status: 500)])
        let r = try await t.send(upload(try await ticket(g)))
        XCTAssertEqual(r.status, 500)
        XCTAssertEqual(w.count, 1)
    }

    func testSessionHasNoDiskCache() {                    // 23
        let c = URLSessionWire.configuration
        XCTAssertNil(c.urlCache)
        XCTAssertNil(c.httpCookieStorage)
    }

    func testKeyRedacted() {                              // 33
        let k = SecretKey("sk-secret")
        XCTAssertEqual("\(k)", "<redacted>")
        XCTAssertFalse(String(reflecting: k).contains("sk-secret"))
        var dumped = ""
        dump(k, to: &dumped)
        XCTAssertFalse(dumped.contains("sk-secret"))
    }

    func testKeyOnlyInHeader() async throws {
        let (w, t, _, _) = setup()
        _ = try await t.send(OutboundRequest(endpoint: remote, providerID: "p", path: "models", payload: .metadata, key: SecretKey("sk-x")))
        XCTAssertEqual(w.requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer sk-x")
    }
}
#endif
