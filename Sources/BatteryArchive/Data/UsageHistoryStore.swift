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
            var rejectedOverlap = false
            do {
                let handle = try FileHandle(forWritingTo: journalURL)
                defer { try? handle.close() }
                var offset = try handle.seekToEnd()
                if needsSeparator {
                    try handle.write(contentsOf: Data([0x0A]))
                    offset += 1
                    needsSeparator = false
                }
                for bucket in buckets {
                    guard bucket.isValid,
                          bucket.end > now.addingTimeInterval(-Self.retention),
                          bucket.start <= now.addingTimeInterval(300),
                          !ids.contains(bucket.id) else { continue }
                    // No double counting overlapping intervals, including after a wall
                    // clock correction. Non-overlapping earlier gaps after rollback are accepted.
                    guard let insertionIndex = nonOverlappingInsertionIndex(forStart: bucket.start, end: bucket.end) else {
                        rejectedOverlap = true
                        continue
                    }
                    let line = try encoder.encode(bucket)
                    var terminated = line
                    terminated.append(0x0A)
                    try handle.write(contentsOf: terminated)
                    let entry = Entry(id: bucket.id, start: bucket.start, end: bucket.end,
                                      timeZoneID: bucket.timeZoneID, offset: offset, length: line.count)
                    if insertionIndex == entries.count {
                        entries.append(entry)
                    } else {
                        entries.insert(entry, at: insertionIndex)
                    }
                    ids.insert(bucket.id)
                    offset += UInt64(terminated.count)
                    dailyStore.include(bucket, allowRecovery: bucket.end > now.addingTimeInterval(-Self.retention))
                }
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
            var replayedIntervals: [(start: Date, end: Date)] = []
            while true {
                let done: Bool = try autoreleasepool {
                    guard let chunk = try handle.read(upToCount: 65_536), !chunk.isEmpty else {
                        return true
                    }
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        let line = Data(pending[..<newline])
                        index(line: line, at: offset, now: now, replayedIntervals: &replayedIntervals)
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
                index(line: pending, at: offset, now: now, replayedIntervals: &replayedIntervals)
                needsSeparator = true
            }
            try dailyStore.flush()
            prune(now: now)
        } catch {
            lastError = "使用历史暂不可读取：\(error.localizedDescription)"
        }
    }

    private func index(
        line: Data,
        at offset: UInt64,
        now: Date,
        replayedIntervals: inout [(start: Date, end: Date)]
    ) {
        guard !line.isEmpty else { return }
        guard let bucket = try? decoder.decode(UsageBucket.self, from: line), bucket.isValid else {
            skippedLines += 1
            return
        }
        guard bucket.start <= now.addingTimeInterval(300) else {
            skippedLines += 1
            return
        }
        guard !ids.contains(bucket.id),
              Self.insertNonOverlapping(start: bucket.start, end: bucket.end, into: &replayedIntervals) else {
            skippedLines += 1
            return
        }
        let withinRetention = bucket.end > now.addingTimeInterval(-Self.retention)
        dailyStore.include(bucket, allowRecovery: withinRetention)
        guard withinRetention else {
            expiredLines += 1
            return
        }
        guard let insertionIndex = nonOverlappingInsertionIndex(forStart: bucket.start, end: bucket.end) else {
            skippedLines += 1
            return
        }
        ids.insert(bucket.id)
        let entry = Entry(id: bucket.id, start: bucket.start, end: bucket.end,
                          timeZoneID: bucket.timeZoneID, offset: offset, length: line.count)
        if insertionIndex == entries.count {
            entries.append(entry)
        } else {
            entries.insert(entry, at: insertionIndex)
        }
    }

    /// 返回 `entries`（按 `(start, end)` 升序且两两不重叠）的合法插入位置；若与任意既有区间重叠则返回 nil。
    private func nonOverlappingInsertionIndex(forStart start: Date, end: Date) -> Int? {
        if let last = entries.last, start >= last.end {
            return entries.count
        }
        var lo = 0
        var hi = entries.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if entries[mid].start < start {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0, entries[lo - 1].end > start { return nil }
        if lo < entries.count, entries[lo].start < end { return nil }
        return lo
    }

    /// 将 `[start, end)` 插入有序不重叠并自动合并相邻区间的重放集合；若发生重叠返回 false。
    private static func insertNonOverlapping(
        start: Date,
        end: Date,
        into intervals: inout [(start: Date, end: Date)]
    ) -> Bool {
        if let last = intervals.last, start >= last.end {
            if start == last.end {
                intervals[intervals.count - 1].end = end
            } else {
                intervals.append((start, end))
            }
            return true
        }
        var lo = 0
        var hi = intervals.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if intervals[mid].start < start {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0, intervals[lo - 1].end > start { return false }
        if lo < intervals.count, intervals[lo].start < end { return false }

        intervals.insert((start, end), at: lo)
        if lo + 1 < intervals.count, intervals[lo].end == intervals[lo + 1].start {
            intervals[lo].end = intervals[lo + 1].end
            intervals.remove(at: lo + 1)
        }
        if lo > 0, intervals[lo - 1].end == intervals[lo].start {
            intervals[lo - 1].end = intervals[lo].end
            intervals.remove(at: lo)
        }
        return true
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
        let directory = journalURL.deletingLastPathComponent()
        let tempURL = directory.appendingPathComponent(".\(journalURL.lastPathComponent).compact-\(UUID().uuidString).tmp")
        var tempExists = false
        defer {
            if tempExists {
                try? FileManager.default.removeItem(at: tempURL)
            }
        }

        guard FileManager.default.createFile(atPath: tempURL.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown)
        }
        tempExists = true

        var updated: [Entry] = []
        updated.reserveCapacity(entries.count)
        let chunkLimit = 65_536

        do {
            let readHandle = try FileHandle(forReadingFrom: journalURL)
            defer { try? readHandle.close() }
            let writeHandle = try FileHandle(forWritingTo: tempURL)
            var writeClosed = false
            defer {
                if !writeClosed {
                    try? writeHandle.close()
                }
            }

            var buffer = Data(capacity: chunkLimit)
            var nextOffset: UInt64 = 0

            for var entry in entries {
                try autoreleasepool {
                    try readHandle.seek(toOffset: entry.offset)
                    guard let line = try readHandle.read(upToCount: entry.length), line.count == entry.length else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    entry.offset = nextOffset
                    nextOffset += UInt64(line.count + 1)
                    buffer.append(line)
                    buffer.append(0x0A)
                    updated.append(entry)
                    if buffer.count >= chunkLimit {
                        try writeHandle.write(contentsOf: buffer)
                        buffer.removeAll(keepingCapacity: true)
                    }
                }
            }
            if !buffer.isEmpty {
                try writeHandle.write(contentsOf: buffer)
                buffer.removeAll(keepingCapacity: false)
            }
            try writeHandle.synchronize()
            try writeHandle.close()
            writeClosed = true
        }

        _ = try FileManager.default.replaceItemAt(journalURL, withItemAt: tempURL)
        tempExists = false
        entries = updated
        expiredLines = 0
        needsSeparator = false
    }
}
