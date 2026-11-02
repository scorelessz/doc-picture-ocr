import DocOCRAppCore
import Foundation
import XCTest

final class SpyFS: CleanupFS, @unchecked Sendable {
    let real = RealCleanupFS()
    var removed: [URL] = [], trashed: [URL] = []
    func size(_ u: URL) -> Int64 { real.size(u) }
    func remove(_ u: URL) throws { removed.append(u); try real.remove(u) }
    func trash(_ u: URL) throws { trashed.append(u) }     // 不真进废纸篓
}

final class CleanupTests: XCTestCase {
    private var root: URL!, out: URL!, pdf: URL!, h: History!
    private let fm = FileManager.default

    override func setUpWithError() throws {
        root = fm.temporaryDirectory.appendingPathComponent("clean-\(UUID().uuidString)", isDirectory: true).resolvingSymlinksInPath()
        out = root.appendingPathComponent("out", isDirectory: true)
        try fm.createDirectory(at: out.appendingPathComponent(".work/书/书.pages"), withIntermediateDirectories: true)
        pdf = root.appendingPathComponent("书.pdf")
        try Data("pdf".utf8).write(to: pdf)
        try Data("j".utf8).write(to: out.appendingPathComponent(".work/书/a.json"))
        for f in ["书.md", "书.searchable.pdf", "书.report.md", "书.uploads.jsonl"] { try Data("o".utf8).write(to: out.appendingPathComponent(f)) }
        h = History(url: root.appendingPathComponent("h.json"))
    }

    override func tearDownWithError() throws { try? fm.removeItem(at: root) }

    private func rec(pdf p: String? = nil, outdir: String? = nil, state: String = "done", age: Double = 0) -> HistoryRecord {
        var r = HistoryRecord(pdf: p ?? pdf.path, outdir: outdir ?? out.path, startedAt: Date().addingTimeInterval(-age * 86400), state: state)
        r.outputs = ["书.md", "书.searchable.pdf", "书.report.md"].map { out.appendingPathComponent($0).path }
        h.upsert(r)
        return r
    }

    private var fileCount: Int { (fm.enumerator(atPath: root.path)?.allObjects.count) ?? 0 }

    func testRecordsOnlyLeavesFiles() {                  // a, f
        _ = rec()
        let n = fileCount, fs = SpyFS(), p = planCleanup(h.records, filter: .all, activePDFs: [], fs: fs)
        let r = runCleanup(p, work: false, trashOutputs: false, history: h, fs: fs)
        XCTAssertEqual(r.records, 1)
        XCTAssertTrue(h.records.isEmpty)
        XCTAssertEqual(fileCount, n)
        XCTAssertTrue(fs.removed.isEmpty && fs.trashed.isEmpty)
    }

    func testWorkRemovesOnlyThatDirectory() {            // b
        _ = rec()
        let fs = SpyFS(), p = planCleanup(h.records, filter: .all, activePDFs: [], fs: fs)
        runCleanup(p, work: true, trashOutputs: false, history: h, fs: fs)
        XCTAssertEqual(fs.removed.map(\.lastPathComponent), ["书"])
        XCTAssertFalse(fm.fileExists(atPath: out.appendingPathComponent(".work/书").path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent(".work").path))
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("书.md").path))
        XCTAssertTrue(fm.fileExists(atPath: pdf.path))
    }

    func testEscapesRejected() throws {                  // c
        XCTAssertNil(safeWorkDirectory(rec(pdf: "/x/..")))
        XCTAssertNil(safeWorkDirectory(rec(outdir: "/")))
        let victim = root.appendingPathComponent("victim", isDirectory: true)
        try fm.createDirectory(at: victim, withIntermediateDirectories: true)
        try Data("v".utf8).write(to: victim.appendingPathComponent("keep"))
        try fm.removeItem(at: out.appendingPathComponent(".work/书"))
        try fm.createSymbolicLink(at: out.appendingPathComponent(".work/书"), withDestinationURL: victim)
        XCTAssertNil(safeWorkDirectory(rec()))
        let dotWork = root.appendingPathComponent("o2", isDirectory: true)
        try fm.createDirectory(at: dotWork, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: dotWork.appendingPathComponent(".work"), withDestinationURL: victim)
        XCTAssertNil(safeWorkDirectory(rec(outdir: dotWork.path)))
        let fs = SpyFS(), p = planCleanup(h.records, filter: .all, activePDFs: [], fs: fs)
        runCleanup(p, work: true, trashOutputs: false, history: h, fs: fs)
        XCTAssertTrue(fm.fileExists(atPath: victim.appendingPathComponent("keep").path))
    }

    func testOutputsCannotPointOutsideOrAtSource() throws {
        var r = rec()
        r.outputs = [pdf.path, root.appendingPathComponent("别的.md").path, out.appendingPathComponent("../书.md").path, out.appendingPathComponent("书.md").path]
        XCTAssertEqual(safeOutputs(r).map(\.lastPathComponent).sorted(), ["书.md", "书.uploads.jsonl"])
    }

    func testRunningNotCleaned() {                       // d
        _ = rec(state: "running")
        _ = rec(pdf: "/q/排队.pdf")
        let p = planCleanup(h.records, filter: .all, activePDFs: ["/q/排队.pdf"])
        XCTAssertTrue(p.items.isEmpty)
        XCTAssertEqual(p.skippedActive, 2)
    }

    func testOutputsGoToTrashOnly() {                    // e
        _ = rec()
        let fs = SpyFS(), p = planCleanup(h.records, filter: .all, activePDFs: [], fs: fs)
        runCleanup(p, work: false, trashOutputs: true, history: h, fs: fs)
        XCTAssertEqual(Set(fs.trashed.map(\.lastPathComponent)), ["书.md", "书.searchable.pdf", "书.report.md", "书.uploads.jsonl"])
        XCTAssertTrue(fs.removed.isEmpty)
    }

    func testMissingFilesCountAsClean() throws {
        _ = rec()
        try fm.removeItem(at: out.appendingPathComponent(".work/书"))
        let fs = SpyFS(), r = runCleanup(planCleanup(h.records, filter: .all, activePDFs: [], fs: fs), work: true, trashOutputs: false, history: h, fs: fs)
        XCTAssertEqual(r.failed, 0)
        XCTAssertEqual(r.records, 1)
    }

    func testFilters() {
        _ = rec(age: 40)
        _ = rec(state: "failed")
        XCTAssertEqual(planCleanup(h.records, filter: .olderThan(days: 30), activePDFs: []).items.count, 1)
        XCTAssertEqual(planCleanup(h.records, filter: .unfinished, activePDFs: []).items.count, 1)
    }

    func testAutoCleanKeepsRecordsAndOutputs() {
        let r = rec(age: 40), fs = SpyFS(), p = planCleanup(h.records, filter: .olderThan(days: 30), activePDFs: [], fs: fs)
        runCleanup(p, work: true, trashOutputs: false, removeRecords: false, history: h, fs: fs)
        XCTAssertEqual(h.records.map(\.id), [r.id])
        XCTAssertTrue(fm.fileExists(atPath: out.appendingPathComponent("书.md").path))
    }
}
