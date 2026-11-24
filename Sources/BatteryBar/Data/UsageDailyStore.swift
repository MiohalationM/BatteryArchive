import Foundation

/// DataStore's serial queue owns this store. One atomic daily checkpoint per batch.
final class UsageDailyStore {
    private let directory: URL
    private var summaries: [String: UsageDailySummary] = [:]
    private var recoveredSummaries: [String: UsageDailySummary] = [:]
    private var dirty = Set<String>()
    private var unreadableFiles = Set<String>()
    private var directoryUnreadable = false
    private(set) var loadError: String?

    // A damaged checkpoint still needs the journal as its recovery source.
    var canDiscardDetailedHistory: Bool {
        !directoryUnreadable && unreadableFiles.isEmpty && dirty.isEmpty
    }

    init(directory: URL) {
        self.directory = directory.appendingPathComponent("usage-daily", isDirectory: true)
        guard FileManager.default.fileExists(atPath: self.directory.path) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(at: self.directory, includingPropertiesForKeys: nil)
            for file in files where file.pathExtension == "json" {
                do {
                    let summary = try JSONDecoder().decode(UsageDailySummary.self, from: Data(contentsOf: file))
                    guard summary.isValid, file.lastPathComponent == filename(summary.id) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    summaries[summary.id] = summary
                } catch {
                    // Preserve damaged checkpoints; one bad day must not stop other days.
                    unreadableFiles.insert(file.lastPathComponent)
                    loadError = "部分日使用汇总不可读，累计可能不完整：\(error.localizedDescription)"
                }
            }
        } catch {
            directoryUnreadable = true
            loadError = "日使用汇总读取失败，累计可能不完整：\(error.localizedDescription)"
        }
    }

    private func filename(_ id: String) -> String {
        Data(id.utf8).base64EncodedString().replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-") + ".json"
    }

    func include(_ bucket: UsageBucket, allowRecovery: Bool = false) {
        guard !directoryUnreadable, bucket.isValid, bucket.knownSeconds > 0 else { return }
        let seed = UsageDailySummary(bucket: bucket)
        if unreadableFiles.contains(filename(seed.id)) {
            guard allowRecovery else { return }
            var summary = recoveredSummaries[seed.id] ?? seed
            let previous = summary.appliedThrough
            summary.include(bucket)
            guard summary.appliedThrough != previous else { return }
            recoveredSummaries[seed.id] = summary
            loadError = "部分日汇总文件损坏，已从保留明细临时恢复可读范围（原文件已保留）"
            return
        }
        var summary = summaries[seed.id] ?? seed
        let previous = summary.appliedThrough
        summary.include(bucket)
        guard summary.appliedThrough != previous else { return }
        summaries[summary.id] = summary
        dirty.insert(summary.id)
    }

    func flush() throws {
        guard !directoryUnreadable else { throw CocoaError(.fileReadCorruptFile) }
        guard !dirty.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for id in Array(dirty) {
            guard let summary = summaries[id], summary.isValid else { throw CocoaError(.fileWriteUnknown) }
            try JSONEncoder().encode(summary).write(to: directory.appendingPathComponent(filename(id)), options: .atomic)
            dirty.remove(id)
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
