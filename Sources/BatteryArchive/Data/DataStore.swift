import Foundation
import os

private let dataStoreLogger = Logger(subsystem: "com.batteryarchive", category: "DataStore")

extension Notification.Name {
    /// 快照数组真正完成内存更新与落盘后发送，图表无需再用每秒 tick 轮询。
    static let batterySnapshotsDidChange = Notification.Name("BatteryArchiveSnapshotsDidChange")
    static let batteryUsageDidChange = Notification.Name("BatteryArchiveUsageDidChange")
    static let batteryHealthHistoryDidChange = Notification.Name("BatteryArchiveHealthHistoryDidChange")
}

/// 纯本机 JSONL / JSON 持久化（24h 功耗快照 + 30 天五分钟使用明细 + 长期日汇总 + 永久电池健康台账）。
final class DataStore: @unchecked Sendable {
    static let shared = DataStore()
    static let batteryHealthHistoryDidChange = Notification.Name.batteryHealthHistoryDidChange
    static let legacyDirectoryName = "BatteryBar"

    private let baseDir: URL
    private let snapshotsFile: URL
    private let snapshotJournalFile: URL
    private let usageHistoryStore: UsageHistoryStore
    private let healthHistoryStore: BatteryHealthStore
    private let queue = DispatchQueue(label: "com.batteryarchive.store", qos: .utility)
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    private var snapshots: [BatterySnapshot] = []
    private var journalNeedsSeparator = false
    /// 自上次 compact 以来因保留窗口从内存裁掉、但仍在 journal 文件里的过期行数。
    private var pendingExpiredLines = 0
    /// 过期行累计到该数量才重写 journal（≈1 小时的采样量）
    private static let compactExpiredThreshold = 60
    /// 24h 快照硬上限（每分钟 1 条 = 1,440 条，留少许余量）
    private static let hardCap = 1_500

    /// 首次从历史数据目录升级到 BatteryArchive 时，仅在目标目录不存在且旧目录存在的前提下
    /// 执行原子移动，确保历史快照、使用明细与永久电池健康记录零丢失；目标已存在时绝不覆盖或触碰旧目录。
    static func migrateLegacyDirectoryIfNeeded(
        from legacyDir: URL,
        to targetDir: URL,
        fileManager: FileManager = .default
    ) {
        guard !fileManager.fileExists(atPath: targetDir.path),
              fileManager.fileExists(atPath: legacyDir.path)
        else { return }
        do {
            try fileManager.createDirectory(
                at: targetDir.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fileManager.moveItem(at: legacyDir, to: targetDir)
            dataStoreLogger.notice("Migrated legacy data directory to \(targetDir.lastPathComponent, privacy: .public)")
        } catch {
            dataStoreLogger.error("Failed to migrate legacy data directory: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// 生产环境使用 shared（默认 Application Support 目录）；
    /// 测试可注入临时目录隔离读写。
    init(directory: URL? = nil) {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        if let directory {
            baseDir = directory
        } else {
            let targetDir = appSupport.appendingPathComponent("BatteryArchive", isDirectory: true)
            let legacyDir = appSupport.appendingPathComponent(Self.legacyDirectoryName, isDirectory: true)
            Self.migrateLegacyDirectoryIfNeeded(from: legacyDir, to: targetDir)
            baseDir = targetDir
        }
        snapshotsFile = baseDir.appendingPathComponent("snapshots.json")
        snapshotJournalFile = baseDir.appendingPathComponent("snapshots.jsonl")
        usageHistoryStore = UsageHistoryStore(directory: baseDir)
        healthHistoryStore = BatteryHealthStore(directory: baseDir)

        try? FileManager.default.createDirectory(at: baseDir, withIntermediateDirectories: true)
        load()
    }

    func load() {
        queue.sync {
            switch loadSnapshotJournal() {
            case .loaded(let journalSnapshots):
                snapshots = Self.retainedSnapshots(journalSnapshots, now: Date())
                if snapshots.count != journalSnapshots.count {
                    pendingExpiredLines = 0
                    rewriteSnapshotJournal()
                }
            case .notFound:
                let loaded: [BatterySnapshot] = loadJSON(from: snapshotsFile, backupOnFailure: true) ?? []
                snapshots = Self.retainedSnapshots(loaded, now: Date())
                pendingExpiredLines = 0
                rewriteSnapshotJournal()
            case .readFailed:
                // 磁盘文件存在但临时读取失败时，绝不能以空内容覆盖现有 snapshots.jsonl。
                snapshots = []
            }
        }
    }

    // MARK: - Snapshots

    func saveSnapshot(_ snap: BatterySnapshot) {
        queue.async { [self] in
            snapshots.append(snap)
            appendSnapshotToJournal(snap)

            let retained = Self.retainedSnapshots(
                snapshots, now: snap.timestamp, hours: 24, maxCount: Self.hardCap
            )
            let dropped = snapshots.count - retained.count
            if dropped > 0 {
                snapshots = retained
                pendingExpiredLines += dropped
            }
            if pendingExpiredLines >= Self.compactExpiredThreshold {
                pendingExpiredLines = 0
                rewriteSnapshotJournal()
            }
            postOnMain(.batterySnapshotsDidChange)
        }
    }

    func allSnapshots() -> [BatterySnapshot] {
        queue.sync { snapshots }
    }

    func localSnapshots(limit: Int = 1_500) -> [BatterySnapshot] {
        queue.sync {
            guard limit > 0 else { return [] }
            return Array(snapshots.suffix(limit))
        }
    }

    // MARK: - Local usage history

    var usageMeasurementEpoch: UUID { queue.sync { usageHistoryStore.measurementEpoch } }

    func saveUsageBuckets(_ buckets: [UsageBucket]) {
        guard !buckets.isEmpty else { return }
        queue.async { [self] in
            usageHistoryStore.append(buckets)
            postOnMain(.batteryUsageDidChange)
        }
    }

    func usageHistory(in interval: DateInterval, now: Date = Date()) -> UsageHistoryPage {
        queue.sync { usageHistoryStore.read(in: interval, now: now) }
    }

    func usageDailySummaries() -> [UsageDailySummary] {
        queue.sync { usageHistoryStore.dailySummaries() }
    }

    // MARK: - Local battery health history

    func recordHealthSample(
        date: Date,
        systemHealthPercent: Double?,
        systemHealthReadAt: Date? = nil,
        fullChargeCapacityMah: Int?,
        nominalCapacityMah: Int?,
        designCapacityMah: Int,
        cycleCount: Int,
        designCycleCount: Int?,
        temperatureC: Double?
    ) {
        queue.async { [self] in
            let changed = healthHistoryStore.record(
                date: date,
                systemHealthPercent: systemHealthPercent,
                systemHealthReadAt: systemHealthReadAt,
                fullChargeCapacityMah: fullChargeCapacityMah,
                nominalCapacityMah: nominalCapacityMah,
                designCapacityMah: designCapacityMah,
                cycleCount: cycleCount,
                designCycleCount: designCycleCount,
                temperatureC: temperatureC
            )
            if changed {
                postOnMain(.batteryHealthHistoryDidChange)
            }
        }
    }

    func healthHistory() -> [BatteryHealthRecord] {
        queue.sync { healthHistoryStore.allRecords() }
    }

    /// 测试钩子：等待队列上已入队的写操作完成，并将防抖暂存的健康峰值补刷落盘。
    func flushPendingWritesForTesting() {
        queue.sync {
            healthHistoryStore.flushPending()
        }
    }

    /// 退出路径同步排空（applicationWillTerminate 在 stop() 之后调用）。
    func flushNow() {
        queue.sync {
            healthHistoryStore.flushPending()
        }
    }

    // MARK: - Retention & Journal helpers

    /// 只保留 24 小时时间窗口内的记录，并用硬上限防御异常高频写入或坏时间戳。
    static func retainedSnapshots(
        _ source: [BatterySnapshot],
        now: Date,
        hours: TimeInterval = 24,
        maxCount: Int = 1_500
    ) -> [BatterySnapshot] {
        guard maxCount > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-hours * 3600)
        let futureBound = now.addingTimeInterval(300)
        var inWindow = source
            .filter { $0.timestamp >= cutoff && $0.timestamp <= futureBound }
            .sorted { $0.timestamp < $1.timestamp }
        if inWindow.count > maxCount {
            inWindow = Array(inWindow.suffix(maxCount))
        }
        return inWindow
    }

    private enum JournalLoadResult {
        case loaded([BatterySnapshot])
        case notFound
        case readFailed
    }

    private func loadSnapshotJournal() -> JournalLoadResult {
        guard FileManager.default.fileExists(atPath: snapshotJournalFile.path) else {
            return .notFound
        }
        let data: Data
        do {
            data = try Data(contentsOf: snapshotJournalFile)
        } catch {
            dataStoreLogger.error("Read snapshots.jsonl failed: \(error.localizedDescription, privacy: .public)")
            return .readFailed
        }
        journalNeedsSeparator = !data.isEmpty && data.last != 0x0A
        var decoded: [BatterySnapshot] = []
        for line in data.split(separator: 0x0A) where !line.isEmpty {
            autoreleasepool {
                do {
                    decoded.append(try decoder.decode(BatterySnapshot.self, from: Data(line)))
                } catch {
                    dataStoreLogger.error("Skip corrupt snapshot journal line: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
        if decoded.isEmpty, FileManager.default.fileExists(atPath: snapshotsFile.path) {
            dataStoreLogger.notice("Snapshot journal empty, falling back to legacy snapshots.json")
            return .notFound
        }
        return .loaded(decoded)
    }

    private func appendSnapshotToJournal(_ snapshot: BatterySnapshot) {
        do {
            var line = try encoder.encode(snapshot)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: snapshotJournalFile.path) {
                try line.write(to: snapshotJournalFile, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: snapshotJournalFile)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if journalNeedsSeparator {
                try handle.write(contentsOf: Data([0x0A]))
                journalNeedsSeparator = false
            }
            try handle.write(contentsOf: line)
        } catch {
            dataStoreLogger.error("Append snapshots.jsonl failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func rewriteSnapshotJournal() {
        do {
            var data = Data()
            for snapshot in snapshots {
                try autoreleasepool {
                    data.append(try encoder.encode(snapshot))
                    data.append(0x0A)
                }
            }
            try data.write(to: snapshotJournalFile, options: .atomic)
            journalNeedsSeparator = false
        } catch {
            dataStoreLogger.error("Rewrite snapshots.jsonl failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func loadJSON<T: Decodable>(from url: URL, backupOnFailure: Bool = false) -> T? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode(T.self, from: data)
        } catch {
            dataStoreLogger.error("Load \(url.lastPathComponent, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            if backupOnFailure {
                let backupURL = url.appendingPathExtension("bak")
                try? FileManager.default.removeItem(at: backupURL)
                try? FileManager.default.copyItem(at: url, to: backupURL)
                dataStoreLogger.notice("Backed up corrupted \(url.lastPathComponent, privacy: .public) to .bak")
            }
            return nil
        }
    }

    private func postOnMain(_ name: Notification.Name) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: name, object: nil)
        }
    }
}
