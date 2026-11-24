import Foundation
import os

private let batteryHealthStoreLogger = Logger(subsystem: "com.batteryarchive", category: "BatteryHealthStore")

/// 永久本机电池健康台账（`battery-health-history.jsonl`），由 `DataStore` 串行队列独占访问。
///
/// 关键约束：
/// - 永久保留全部历史日记录，绝不做 30 天裁剪；
/// - 每日最多保留一条归并后的记录，按 `dayKey` 去重（加载时较晚的合法行胜出）；
/// - 绝不用 `nil` 覆盖当日已有合法的 `systemHealthPercent` 或 `designCycleCount`；
/// - 写入防抖避免高频轮询反复刷盘；冗余行累计达到 30 条时原子压缩。
final class BatteryHealthStore {
    let fileURL: URL
    private let directory: URL
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    /// 内存中最新的每日归并记录（包含低于落盘防抖阈值的真实峰值更新）
    private var recordsByDay: [String: BatteryHealthRecord] = [:]
    /// 已落盘的每日记录基线，用于判断防抖阈值与 `flushPending()` 补刷
    private var persistedByDay: [String: BatteryHealthRecord] = [:]
    private var redundantLines = 0
    private var needsSeparator = false
    private var loadFailed = false
    private(set) var skippedLines = 0

    static let compactThreshold = 30

    init(directory: URL) {
        self.directory = directory
        self.fileURL = directory.appendingPathComponent("battery-health-history.jsonl")
        load()
    }

    @discardableResult
    func record(
        date: Date,
        systemHealthPercent: Double?,
        systemHealthReadAt: Date? = nil,
        fullChargeCapacityMah: Int?,
        nominalCapacityMah: Int?,
        designCapacityMah: Int,
        cycleCount: Int,
        designCycleCount: Int?,
        temperatureC: Double?,
        calendar: Calendar = .current
    ) -> Bool {
        guard date.timeIntervalSince1970.isFinite,
              designCapacityMah > 0, designCapacityMah <= 100_000,
              cycleCount >= 0, cycleCount <= 10_000
        else { return false }

        let maxAllowedCapacity = BatteryHealthRecord.maximumValidCapacity(forDesignCapacity: designCapacityMah)
        let incomingHealth: (percent: Double, readAt: Date?)? = {
            guard let percent = systemHealthPercent,
                  percent.isFinite, percent > 0, percent <= 100
            else { return nil }
            if let readAt = systemHealthReadAt {
                guard readAt.timeIntervalSince1970.isFinite,
                      calendar.isDate(readAt, inSameDayAs: date)
                else { return nil }
                return (percent, readAt)
            }
            return (percent, nil)
        }()
        let sanitizedFCC = fullChargeCapacityMah.flatMap { value in
            (1...maxAllowedCapacity).contains(value) ? value : nil
        }
        let sanitizedNominal = nominalCapacityMah.flatMap { value in
            (1...maxAllowedCapacity).contains(value) ? value : nil
        }
        let sanitizedDesignCycle = designCycleCount.flatMap { value in
            (1...10_000).contains(value) ? value : nil
        }
        let sanitizedTemp = temperatureC.flatMap { value in
            (value.isFinite && value >= -20 && value <= 100) ? value : nil
        }

        let dayKey = BatteryHealthRecord.dayKey(for: date, calendar: calendar)
        let existing = recordsByDay[dayKey]

        let existingFCC = existing?.fullChargeCapacityMah.flatMap { (1...maxAllowedCapacity).contains($0) ? $0 : nil }
        let existingNominal = existing?.nominalCapacityMah.flatMap { (1...maxAllowedCapacity).contains($0) ? $0 : nil }

        let mergedHealth: Double?
        let mergedHealthReadAt: Date?
        if let incomingHealth {
            mergedHealth = incomingHealth.percent
            if let readAt = incomingHealth.readAt {
                mergedHealthReadAt = readAt
            } else if existing?.systemHealthPercent == incomingHealth.percent {
                mergedHealthReadAt = existing?.systemHealthReadAt
            } else {
                mergedHealthReadAt = nil
            }
        } else {
            mergedHealth = existing?.systemHealthPercent
            mergedHealthReadAt = existing?.systemHealthReadAt
        }
        let mergedFCC = sanitizedFCC ?? existingFCC
        let mergedNominal = sanitizedNominal ?? existingNominal
        let mergedDesignCycle = sanitizedDesignCycle ?? existing?.designCycleCount
        let mergedPeakTemp: Double? = switch (existing?.peakTemperatureC, sanitizedTemp) {
        case let (old?, new?): max(old, new)
        case let (old?, nil): old
        case let (nil, new?): new
        case (nil, nil): nil
        }

        let candidate = BatteryHealthRecord(
            schemaVersion: 1,
            dayKey: dayKey,
            recordedAt: date,
            systemHealthPercent: mergedHealth,
            fullChargeCapacityMah: mergedFCC,
            nominalCapacityMah: mergedNominal,
            designCapacityMah: designCapacityMah,
            cycleCount: cycleCount,
            designCycleCount: mergedDesignCycle,
            peakTemperatureC: mergedPeakTemp,
            systemHealthReadAt: mergedHealthReadAt
        )
        guard candidate.isValid else { return false }

        if let persisted = persistedByDay[dayKey], shouldDebounce(existing: persisted, candidate: candidate) {
            // 始终在内存保留最新精确归并结果（如 <0.5°C 的日最高温），避免读取延迟与退出丢失。
            if existing == nil || Self.hasMeaningfulDifference(existing!, candidate) {
                recordsByDay[dayKey] = candidate
            }
            return false
        }

        guard appendRecord(candidate) else { return false }

        let hadPersisted = persistedByDay[dayKey] != nil
        recordsByDay[dayKey] = candidate
        persistedByDay[dayKey] = candidate
        if hadPersisted {
            redundantLines += 1
        }
        if redundantLines >= Self.compactThreshold, !loadFailed {
            compact()
        }
        return true
    }

    /// 将内存中已更新但因防抖尚未落盘的日记录补刷到磁盘（如退出前 `DataStore.flushNow()`）。
    func flushPending() {
        var didWrite = false
        for dayKey in recordsByDay.keys.sorted() {
            guard let record = recordsByDay[dayKey] else { continue }
            let persisted = persistedByDay[dayKey]
            if let persisted, !Self.hasMeaningfulDifference(persisted, record) {
                continue
            }
            guard appendRecord(record) else { continue }
            let hadPersisted = persisted != nil
            persistedByDay[dayKey] = record
            if hadPersisted {
                redundantLines += 1
            }
            didWrite = true
        }
        if didWrite, redundantLines >= Self.compactThreshold, !loadFailed {
            compact()
        }
    }

    func allRecords() -> [BatteryHealthRecord] {
        recordsByDay.values.sorted { $0.dayKey < $1.dayKey }
    }

    // MARK: - Debounce

    private static func hasMeaningfulDifference(_ lhs: BatteryHealthRecord, _ rhs: BatteryHealthRecord) -> Bool {
        lhs.systemHealthPercent != rhs.systemHealthPercent
            || lhs.systemHealthReadAt != rhs.systemHealthReadAt
            || lhs.fullChargeCapacityMah != rhs.fullChargeCapacityMah
            || lhs.nominalCapacityMah != rhs.nominalCapacityMah
            || lhs.designCapacityMah != rhs.designCapacityMah
            || lhs.cycleCount != rhs.cycleCount
            || lhs.designCycleCount != rhs.designCycleCount
            || lhs.peakTemperatureC != rhs.peakTemperatureC
    }

    private func shouldDebounce(existing: BatteryHealthRecord, candidate: BatteryHealthRecord) -> Bool {
        existing.systemHealthPercent == candidate.systemHealthPercent
            && existing.cycleCount == candidate.cycleCount
            && existing.designCapacityMah == candidate.designCapacityMah
            && existing.designCycleCount == candidate.designCycleCount
            && Self.capacityWithinThreshold(old: existing.fullChargeCapacityMah, new: candidate.fullChargeCapacityMah)
            && Self.capacityWithinThreshold(old: existing.nominalCapacityMah, new: candidate.nominalCapacityMah)
            && Self.peakTemperatureWithinThreshold(old: existing.peakTemperatureC, new: candidate.peakTemperatureC)
    }

    private static func capacityWithinThreshold(old: Int?, new: Int?) -> Bool {
        switch (old, new) {
        case (nil, nil):
            return true
        case let (old?, new?):
            return abs(new - old) < 10
        default:
            return false
        }
    }

    private static func peakTemperatureWithinThreshold(old: Double?, new: Double?) -> Bool {
        switch (old, new) {
        case (nil, nil):
            return true
        case (nil, .some):
            return false
        case (.some, nil):
            return true
        case let (old?, new?):
            // 容忍 binary64 减法浮点尾差（如 32.7 - 32.2 == 0.49999999999999645）
            return (new - old) < (0.5 - 1e-9)
        }
    }

    // MARK: - Persistence

    private func load() {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            loadFailed = true
            batteryHealthStoreLogger.error("Read battery-health-history.jsonl failed: \(error.localizedDescription, privacy: .public)")
            return
        }

        needsSeparator = !data.isEmpty && data.last != 0x0A
        for rawLine in data.split(separator: 0x0A) where !rawLine.isEmpty {
            autoreleasepool {
                do {
                    let record = try decoder.decode(BatteryHealthRecord.self, from: Data(rawLine))
                    guard record.isValid else {
                        skippedLines += 1
                        redundantLines += 1
                        return
                    }
                    if recordsByDay[record.dayKey] != nil {
                        redundantLines += 1
                    }
                    recordsByDay[record.dayKey] = record
                    persistedByDay[record.dayKey] = record
                } catch {
                    skippedLines += 1
                    redundantLines += 1
                    batteryHealthStoreLogger.error("Skip corrupt battery health line: \(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }

    private func appendRecord(_ record: BatteryHealthRecord) -> Bool {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var line = try encoder.encode(record)
            line.append(0x0A)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: .atomic)
                needsSeparator = false
                return true
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            if needsSeparator {
                try handle.write(contentsOf: Data([0x0A]))
                needsSeparator = false
            }
            try handle.write(contentsOf: line)
            return true
        } catch {
            batteryHealthStoreLogger.error("Append battery-health-history.jsonl failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func compact() {
        do {
            var data = Data()
            for record in allRecords() {
                try autoreleasepool {
                    data.append(try encoder.encode(record))
                    data.append(0x0A)
                }
            }
            try data.write(to: fileURL, options: .atomic)
            persistedByDay = recordsByDay
            redundantLines = 0
            needsSeparator = false
        } catch {
            batteryHealthStoreLogger.error("Compact battery-health-history.jsonl failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
