#if canImport(CryptoKit)
import Foundation
import XCTest
@testable import OCREngines

final class ModelStoreTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("vl-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func file(_ name: String, _ text: String) throws -> VLFile {
        let u = root.appendingPathComponent("src").appendingPathComponent(name)
        try Data(text.utf8).write(to: u)
        return VLFile(name: name, sha256: try ModelStore.sha256(u), size: text.utf8.count)
    }

    func testVLFetchInstallsVerifiedFiles() throws {
        let files = [try file("a.json", "aaa"), try file("b.bin", "bbb")]
        let dir = root.appendingPathComponent("vl")
        try ModelStore.fetchVL(base: root.appendingPathComponent("src").absoluteString, files: files, into: dir) { _ in }
        XCTAssertEqual(VLModel.problems(dir, files: files), [])
    }

    func testVLFetchRefusesBadChecksumAndInstallsNothing() throws {
        let good = try file("a.json", "aaa")
        var bad = try file("b.bin", "bbb")
        bad = VLFile(name: bad.name, sha256: String(repeating: "0", count: 64), size: bad.size)
        let dir = root.appendingPathComponent("vl")
        XCTAssertThrowsError(try ModelStore.fetchVL(base: root.appendingPathComponent("src").absoluteString, files: [good, bad], into: dir) { _ in })
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".vl-partial/b.bin").path))
    }

    func testVLFetchFailureKeepsOldInstall() throws {
        let f = try file("a.json", "aaa")
        let dir = root.appendingPathComponent("vl")
        try ModelStore.fetchVL(base: root.appendingPathComponent("src").absoluteString, files: [f], into: dir) { _ in }
        let bad = VLFile(name: "a.json", sha256: String(repeating: "0", count: 64), size: 3)
        XCTAssertThrowsError(try ModelStore.fetchVL(base: root.appendingPathComponent("src").absoluteString, files: [bad], into: dir) { _ in })
        XCTAssertEqual(VLModel.problems(dir, files: [f]), [])
    }

    func testProblemsReportsMissingFile() {
        XCTAssertEqual(VLModel.problems(root, files: [VLFile(name: "x", sha256: "0", size: 1)]), ["x"])
    }
}
#endif
