import Foundation

/// DataStore's serial queue owns this store. One atomic daily checkpoint per batch.
final class UsageDailyStore {
    private struct RecoveredDailySummary: Codable, Equatable, Sendable {
        var version = 1
        var summary: UsageDailySummary
        var recoveredFrom: Date
        var recoveredThrough: Date

        var isValid: Bool {
            version == 1
                && summary.isValid
                && recoveredFrom.timeIntervalSince1970.isFinite
                && recoveredThrough.timeIntervalSince1970.isFinite
                && abs(recoveredFrom.timeIntervalSince(summary.firstRecord)) <= 0.001
                && abs(recoveredThrough.timeIntervalSince(summary.appliedThrough)) <= 0.001
        }
    }

    private static let recoverySuffix = ".recovered.json"

    private let directory: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var summaries: [String: UsageDailySummary] = [:]
    private var recoveredSummaries: [String: UsageDailySummary] = [:]
    private var dirty = Set<String>()
    private var recoveredDirty = Set<String>()
    private var unreadableFiles = Set<String>()
    private var directoryUnreadable = false
    private(set) var loadError: String?

    // A damaged checkpoint still needs the journal as its recovery source.
    var canDiscardDetailedHistory: Bool {
        !directoryUnreadable && unreadableFiles.isEmpty && dirty.isEmpty && recoveredDirty.isEmpty
    }

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("usage-daily", isDirectory: true)
        guard FileManager.default.fileExists(atPath: self.directory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
            var loadedPrimaryFiles = Set<String>()
            var recoveryFiles: [URL] = []

            for file in files {
                let name = file.lastPathComponent
                if name.hasSuffix(Self.recoverySuffix) {
                    recoveryFiles.append(file)
                    continue
                }
                guard file.pathExtension == "json" else { continue }
                autoreleasepool {
                    do {
                        let summary = try decoder.decode(UsageDailySummary.self, from: Data(contentsOf: file))
                        guard summary.isValid, name == filename(summary.id) else {
                            throw CocoaError(.fileReadCorruptFile)
                        }
                        summaries[summary.id] = summary
                        loadedPrimaryFiles.insert(name)
                    } catch {
                        // Preserve damaged checkpoints; one bad day must not stop other days.
                        unreadableFiles.insert(name)
                        loadError = "部分日使用汇总不可读，累计可能不完整：\(error.localizedDescription)"
                    }
                }
            }

            for file in recoveryFiles {
                let name = file.lastPathComponent
                let primaryName = String(name.dropLast(Self.recoverySuffix.count)) + ".json"
                if loadedPrimaryFiles.contains(primaryName) {
                    try? FileManager.default.removeItem(at: file)
                    continue
                }
                guard unreadableFiles.contains(primaryName) else { continue }
                autoreleasepool {
                    guard let data = try? Data(contentsOf: file),
                          let record = try? decoder.decode(RecoveredDailySummary.self, from: data),
                          record.isValid,
                          name == recoveryFilename(record.summary.id),
                          unreadableFiles.contains(filename(record.summary.id)) else { return }
                    recoveredSummaries[record.summary.id] = record.summary
                }
            }

            if !recoveredSummaries.isEmpty {
                loadError = Self.persistedRecoveryLoadError(for: Array(recoveredSummaries.values))
            }
        } catch {
            directoryUnreadable = true
            loadError = "日使用汇总读取失败，累计可能不完整：\(error.localizedDescription)"
        }
    }

    private func baseName(_ id: String) -> String {
        Data(id.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
    }

    private func filename(_ id: String) -> String {
        baseName(id) + ".json"
    }

    private func recoveryFilename(_ id: String) -> String {
        baseName(id) + Self.recoverySuffix
    }

    private static func persistedRecoveryLoadError(for recovered: [UsageDailySummary]) -> String {
        guard let earliest = recovered.min(by: { $0.firstRecord < $1.firstRecord }),
              let latest = recovered.max(by: { $0.appliedThrough < $1.appliedThrough }) else {
            return "部分日汇总文件损坏，已从明细持久化恢复可读范围（原文件已保留）"
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.timeZone = TimeZone(identifier: earliest.timeZoneID) ?? .current
        formatter.dateFormat = "MM-dd HH:mm"
        let rangeText = "\(formatter.string(from: earliest.firstRecord))–\(formatter.string(from: latest.appliedThrough))"
        return "部分日汇总文件损坏，已从明细持久化恢复可读范围（\(rangeText)，原文件已保留）"
    }

    func include(_ bucket: UsageBucket, allowRecovery: Bool = false) {
        guard !directoryUnreadable, bucket.isValid, bucket.knownSeconds > 0 else { return }
        let seed = UsageDailySummary(bucket: bucket)
        if unreadableFiles.contains(filename(seed.id)) {
            guard allowRecovery else { return }
            var summary = recoveredSummaries[seed.id] ?? seed
            guard summary.include(bucket) else { return }
            recoveredSummaries[seed.id] = summary
            recoveredDirty.insert(seed.id)
            loadError = Self.persistedRecoveryLoadError(for: Array(recoveredSummaries.values))
            return
        }
        var summary = summaries[seed.id] ?? seed
        guard summary.include(bucket) else { return }
        summaries[summary.id] = summary
        dirty.insert(summary.id)
    }

    func flush() throws {
        guard !directoryUnreadable else { throw CocoaError(.fileReadCorruptFile) }
        guard !dirty.isEmpty || !recoveredDirty.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in Array(dirty) {
            try autoreleasepool {
                guard let summary = summaries[id], summary.isValid else { throw CocoaError(.fileWriteUnknown) }
                try encoder.encode(summary).write(to: directory.appendingPathComponent(filename(id)), options: .atomic)
                dirty.remove(id)
            }
        }
        for id in Array(recoveredDirty) {
            try autoreleasepool {
                guard let summary = recoveredSummaries[id], summary.isValid else { throw CocoaError(.fileWriteUnknown) }
                let record = RecoveredDailySummary(
                    summary: summary,
                    recoveredFrom: summary.firstRecord,
                    recoveredThrough: summary.appliedThrough
                )
                try encoder.encode(record).write(
                    to: directory.appendingPathComponent(recoveryFilename(id)),
                    options: .atomic
                )
                recoveredDirty.remove(id)
            }
        }
    }

    func read() -> [UsageDailySummary] {
        var merged = summaries
        for (id, summary) in recoveredSummaries where merged[id] == nil {
            merged[id] = summary
        }
        return merged.values.sorted { $0.date < $1.date }
    }
}
