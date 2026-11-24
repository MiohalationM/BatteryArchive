import Foundation

/// Owned exclusively by DataStore's serial queue. Keeps a small byte-offset index,
/// not thirty days of decoded telemetry. Queries decode only the requested range.
final class UsageHistoryStore {
    private struct Metadata: Codable {
        var schemaVersion = 1
        var measurementEpoch = UUID()
        var createdAt: Date
    }

    private struct Entry {
        var id: String
        var start: Date
        var end: Date
        var timeZoneID: String
        var offset: UInt64
        var length: Int
    }

    let journalURL: URL
    private let metadataURL: URL
    private let metadata: Metadata
    private var needsMetadataWrite = false
    private let dailyStore: UsageDailyStore
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var replayEnd = Date.distantPast
    private var entries: [Entry] = []
    private var ids = Set<String>()
    private var expiredLines = 0
    private var needsSeparator = false
    private(set) var lastError: String?
    private(set) var skippedLines = 0
    static let retention: TimeInterval = 30 * 86_400
    static let hardCap = 10_000

    var measurementEpoch: UUID { metadata.measurementEpoch }

    init(directory: URL, now: Date = Date()) {
        journalURL = directory.appendingPathComponent("usage-history.jsonl")
        metadataURL = directory.appendingPathComponent("usage-history-epoch.json")
        dailyStore = UsageDailyStore(directory: directory)
        if let data = try? Data(contentsOf: metadataURL),
           let saved = try? decoder.decode(Metadata.self, from: data),
           saved.schemaVersion == 1 {
            metadata = saved
        } else {
            metadata = Metadata(createdAt: now)
            // 文件缺失或损坏时下次写入原子覆盖修复，防止每次重启反复生成新 measurementEpoch。
            needsMetadataWrite = true
        }
        loadIndex(now: now)
    }

    func append(_ buckets: [UsageBucket], now: Date = Date()) {
        guard !buckets.isEmpty else { return }
        do {
            if needsMetadataWrite || !FileManager.default.fileExists(atPath: metadataURL.path) {
                try encoder.encode(metadata).write(to: metadataURL, options: .atomic)
                needsMetadataWrite = false
            }
            if !FileManager.default.fileExists(atPath: journalURL.path) {
                try Data().write(to: journalURL, options: .atomic)
            }
            let handle = try FileHandle(forWritingTo: journalURL)
            defer { try? handle.close() }
            var offset = try handle.seekToEnd()
            if needsSeparator {
                try handle.write(contentsOf: Data([0x0A]))
                offset += 1
                needsSeparator = false
            }
            var rejectedOverlap = false
            for bucket in buckets {
                guard bucket.isValid,
                      bucket.end > now.addingTimeInterval(-Self.retention),
                      bucket.start <= now.addingTimeInterval(300),
                      !ids.contains(bucket.id) else { continue }
                // No double counting overlapping intervals, including after a wall
                // clock correction. A later nonoverlapping bucket can recover.
                if let last = entries.last, bucket.start < last.end {
                    rejectedOverlap = true
                    continue
                }
                let line = try encoder.encode(bucket)
                var terminated = line
                terminated.append(0x0A)
                try handle.write(contentsOf: terminated)
                entries.append(Entry(id: bucket.id, start: bucket.start, end: bucket.end,
                                     timeZoneID: bucket.timeZoneID, offset: offset, length: line.count))
                ids.insert(bucket.id)
                offset += UInt64(terminated.count)
                dailyStore.include(bucket, allowRecovery: bucket.end > now.addingTimeInterval(-Self.retention))
            }
            // 先维持 30 天 / 10,000 桶内存索引上限，即使日汇总目录不可读也不能跳过裁剪（物理 compact 仍受 canDiscardDetailedHistory 门控）。
            prune(now: now)
            try dailyStore.flush()
            if expiredLines >= 60, dailyStore.canDiscardDetailedHistory { try compact() }
            lastError = rejectedOverlap ? "使用记录时间重叠，已跳过重叠区间并保存其余记录" : nil
        } catch {
            lastError = "使用记录未能完整保存：\(error.localizedDescription)"
        }
    }

    func read(in interval: DateInterval, now: Date = Date()) -> UsageHistoryPage {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let available = Set(entries.filter { $0.end > cutoff }.map(\.timeZoneID)).sorted()
        var page = UsageHistoryPage(availableTimeZones: available, error: lastError ?? dailyStore.loadError,
                                   skippedLines: skippedLines)
        let selected = entries.filter {
            $0.end > cutoff && $0.end > interval.start && $0.start < interval.end
        }
        guard !selected.isEmpty else { return page }
        do {
            let handle = try FileHandle(forReadingFrom: journalURL)
            defer { try? handle.close() }
            for entry in selected {
                try autoreleasepool {
                    try handle.seek(toOffset: entry.offset)
                    guard let data = try handle.read(upToCount: entry.length),
                          let bucket = try? decoder.decode(UsageBucket.self, from: data),
                          bucket.isValid else {
                        page.skippedLines += 1
                        return
                    }
                    page.buckets.append(bucket)
                }
            }
        } catch {
            page.error = "使用历史暂不可读取：\(error.localizedDescription)"
        }
        return page
    }

    func dailySummaries() -> [UsageDailySummary] { dailyStore.read() }

    private func loadIndex(now: Date) {
        guard FileManager.default.fileExists(atPath: journalURL.path) else { return }
        do {
            let handle = try FileHandle(forReadingFrom: journalURL)
            defer { try? handle.close() }
            var pending = Data()
            var offset: UInt64 = 0
            while true {
                let done: Bool = try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else {
                        return true
                    }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        index(line: line, at: offset, now: now)
                        let consumed = pending.distance(from: pending.startIndex, to: newline) + 1
                        offset += UInt64(consumed)
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                    return false
                }
                if done { break }
            }
            if !pending.isEmpty {
                // A complete JSON final line is accepted; an interrupted one is skipped.
                index(line: pending, at: offset, now: now)
                needsSeparator = true
            }
            try dailyStore.flush()
            prune(now: now)
        } catch {
            lastError = "使用历史暂不可读取：\(error.localizedDescription)"
        }
    }

    private func index(line: Data, at offset: UInt64, now: Date) {
        guard !line.isEmpty else { return }
        guard let bucket = try? decoder.decode(UsageBucket.self, from: line), bucket.isValid else {
            skippedLines += 1
            return
        }
        guard bucket.start <= now.addingTimeInterval(300), bucket.start >= replayEnd else {
            skippedLines += 1
            return
        }
        replayEnd = bucket.end
        let withinRetention = bucket.end > now.addingTimeInterval(-Self.retention)
        dailyStore.include(bucket, allowRecovery: withinRetention)
        guard withinRetention else {
            expiredLines += 1
            return
        }
        guard ids.insert(bucket.id).inserted else { return }
        if let last = entries.last, bucket.start < last.end {
            ids.remove(bucket.id)
            skippedLines += 1
            return
        }
        entries.append(Entry(id: bucket.id, start: bucket.start, end: bucket.end,
                             timeZoneID: bucket.timeZoneID, offset: offset, length: line.count))
    }

    private func prune(now: Date) {
        let cutoff = now.addingTimeInterval(-Self.retention)
        let retained = entries.filter { $0.end > cutoff }
        let dropped = entries.count - retained.count + max(0, retained.count - Self.hardCap)
        entries = Array(retained.suffix(Self.hardCap))
        expiredLines += dropped
        if dropped > 0 { ids = Set(entries.map(\.id)) }
    }

    private func compact() throws {
        let handle = try FileHandle(forReadingFrom: journalURL)
        defer { try? handle.close() }
        var result = Data()
        var updated: [Entry] = []
        for var entry in entries {
            try autoreleasepool {
                try handle.seek(toOffset: entry.offset)
                guard let line = try handle.read(upToCount: entry.length), line.count == entry.length else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                entry.offset = UInt64(result.count)
                result.append(line)
                result.append(0x0A)
                updated.append(entry)
            }
        }
        try result.write(to: journalURL, options: .atomic)
        entries = updated
        expiredLines = 0
        needsSeparator = false
    }
}
