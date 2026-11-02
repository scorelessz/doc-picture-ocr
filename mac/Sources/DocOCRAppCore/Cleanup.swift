import Foundation
import OCRCore

// 清理旧记录。三层：记录、.work 中间文件、输出文件。输出文件只进废纸篓，源 PDF 任何情况都不碰。

public protocol CleanupFS: Sendable {
    func size(_ u: URL) -> Int64
    func remove(_ u: URL) throws
    func trash(_ u: URL) throws
}

public struct RealCleanupFS: CleanupFS {
    public init() {}

    public func size(_ u: URL) -> Int64 {
        let n = Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        return n + directorySize(u)
    }

    public func remove(_ u: URL) throws { try FileManager.default.removeItem(at: u) }
    public func trash(_ u: URL) throws { try FileManager.default.trashItem(at: u, resultingItemURL: nil) }
}

public struct CleanupItem: Sendable, Identifiable {
    public var id: UUID { record.id }
    public let record: HistoryRecord
    public let work: URL?, outputs: [URL]
}

public struct CleanupPlan: Sendable {
    public var items: [CleanupItem] = []
    /// 运行或排队中，不处理
    public var skippedActive = 0
    /// 路径校验没过，只移除记录，不碰文件
    public var rejectedPaths = 0
    public var workBytes: Int64 = 0, outputBytes: Int64 = 0

    public var workPaths: [String] { items.compactMap { $0.work?.path } }
    public var outputPaths: [String] { items.flatMap { $0.outputs.map(\.path) } }
}

public struct CleanupResult: Sendable, Equatable {
    public var records = 0, failed = 0
    public var bytes: Int64 = 0
}

public enum CleanupFilter: Sendable {
    case ids(Set<UUID>), olderThan(days: Int, now: Date = Date()), unfinished, all

    func matches(_ r: HistoryRecord) -> Bool {
        switch self {
        case .ids(let s): return s.contains(r.id)
        case let .olderThan(d, now): return r.startedAt < now.addingTimeInterval(-Double(d) * 86400)
        case .unfinished: return ["failed", "cancelled", "interrupted"].contains(r.state)
        case .all: return true
        }
    }
}

private func isLink(_ u: URL) -> Bool {
    ((try? FileManager.default.attributesOfItem(atPath: u.path)[.type]) as? FileAttributeType) == .typeSymbolicLink
}

/// 只认 <outdir>/.work/<stem>：stem 来自记录，不能带路径，途中不能有符号链接
public func safeWorkDirectory(_ r: HistoryRecord) -> URL? {
    let stem = URL(fileURLWithPath: r.pdf).deletingPathExtension().lastPathComponent
    guard !stem.isEmpty, stem != ".", stem != "..", !stem.contains("/"), !r.outdir.isEmpty, r.outdir != "/" else { return nil }
    let out = URL(fileURLWithPath: r.outdir, isDirectory: true).standardizedFileURL
    let dot = out.appendingPathComponent(".work", isDirectory: true), dir = dot.appendingPathComponent(stem, isDirectory: true)
    if isLink(out) || isLink(dot) || isLink(dir) { return nil }
    let base = out.resolvingSymlinksInPath().path + "/.work/"
    guard dir.resolvingSymlinksInPath().path.hasPrefix(base) else { return nil }
    return dir
}

/// 记录里登记的产物加上传记录：必须直接在 outdir 下，是 App 写的扩展名，不是源 PDF
public func safeOutputs(_ r: HistoryRecord) -> [URL] {
    let out = URL(fileURLWithPath: r.outdir, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath().path
    let stem = URL(fileURLWithPath: r.pdf).deletingPathExtension().lastPathComponent
    let source = URL(fileURLWithPath: r.pdf).standardizedFileURL.resolvingSymlinksInPath().path
    var list = r.outputs.map { URL(fileURLWithPath: $0).standardizedFileURL }
    list.append(URL(fileURLWithPath: r.outdir).appendingPathComponent(stem + ".uploads.jsonl").standardizedFileURL)
    let ok = [".searchable.pdf", ".md", ".uploads.jsonl"]
    return Array(Set(list)).filter { u in
        !isLink(u) && u.deletingLastPathComponent().resolvingSymlinksInPath().path == out && u.resolvingSymlinksInPath().path != source
            && u.lastPathComponent.hasPrefix(stem) && ok.contains { u.lastPathComponent.hasSuffix($0) }
    }.sorted { $0.path < $1.path }
}

public func planCleanup(_ records: [HistoryRecord], filter: CleanupFilter, activePDFs: Set<String>, fs: CleanupFS = RealCleanupFS()) -> CleanupPlan {
    var p = CleanupPlan()
    for r in records where filter.matches(r) {
        if r.state == "running" || activePDFs.contains(r.pdf) {
            p.skippedActive += 1
            continue
        }
        let w = safeWorkDirectory(r), o = safeOutputs(r)
        if w == nil { p.rejectedPaths += 1 }
        p.items.append(CleanupItem(record: r, work: w, outputs: o))
    }
    // 同一本书多条记录共用一个 .work，只算一次
    p.workBytes = Set(p.items.compactMap(\.work)).map(fs.size).reduce(0, +)
    p.outputBytes = Set(p.items.flatMap(\.outputs)).map(fs.size).reduce(0, +)
    return p
}

/// 文件缺失算已清理。文件处理失败的记录留着，下次还能再清。
@discardableResult
public func runCleanup(_ plan: CleanupPlan, work: Bool, trashOutputs: Bool, removeRecords: Bool = true, history: History, fs: CleanupFS = RealCleanupFS()) -> CleanupResult {
    var res = CleanupResult(), gone = Set<UUID>(), seen = Set<URL>()
    let exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }
    func attempt(_ u: URL, _ f: (URL) throws -> Void) -> Bool {
        guard seen.insert(u).inserted, exists(u) else { return true }
        let n = fs.size(u)
        do {
            try f(u)
            res.bytes += n
            return true
        } catch {
            res.failed += 1
            return false
        }
    }
    for i in plan.items {
        var ok = true
        if work, let w = i.work { ok = attempt(w, fs.remove) && ok }
        if trashOutputs { for o in i.outputs { ok = attempt(o, fs.trash) && ok } }
        if ok { gone.insert(i.record.id) }
    }
    if removeRecords {
        history.remove(gone)
        res.records = gone.count
    }
    Log.shared.info("history_cleanup", ["records": .i(res.records), "bytes": .i(Int(res.bytes)), "work": .b(work), "trash_outputs": .b(trashOutputs), "failed": .i(res.failed)])
    return res
}

/// 日志占用
public func logsSize(_ log: URL = AppPaths.log) -> Int64 { directorySize(log.deletingLastPathComponent()) }

/// 删旧日志，正在写的那个清空。调用方之后要重新打开日志。
public func clearLogs(_ log: URL = AppPaths.log) {
    let fm = FileManager.default, dir = log.deletingLastPathComponent()
    for f in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] where f.lastPathComponent != log.lastPathComponent {
        try? fm.removeItem(at: f)
    }
    try? FileHandle(forWritingTo: log).truncate(atOffset: 0)
}
