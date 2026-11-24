import Foundation

/// 每日电池健康长期记录（永久本机保留，不随 30 天使用明细或 24 小时快照裁剪）。
///
/// 口径约束（冻结）：
/// - `systemHealthPercent` 只接受 macOS `system_profiler` 报告的官方「最大容量」，
///   绝不用 `FullChargeCapacity / DesignCapacity` 冒充；
/// - `capacityRatioPercent` 仅作为独立的容量比参考计算属性提供；
/// - 每日最多保留一条归并记录，按本地日历 `dayKey` ("yyyy-MM-dd") 去重。
struct BatteryHealthRecord: Codable, Equatable, Sendable, Identifiable {
    var schemaVersion: Int = 1
    var dayKey: String
    var recordedAt: Date
    /// macOS `system_profiler` 最大容量百分比（0 < v <= 100）；不可用时必须为 nil。
    var systemHealthPercent: Double? = nil
    /// 实际满充容量 FullChargeCapacity（mAh）
    var fullChargeCapacityMah: Int? = nil
    /// 标称满充容量 NominalChargeCapacity（mAh）
    var nominalCapacityMah: Int? = nil
    /// 设计容量 DesignCapacity（mAh）
    var designCapacityMah: Int
    /// 电池循环次数 CycleCount
    var cycleCount: Int
    /// 设计循环次数 DesignCycleCount9C
    var designCycleCount: Int? = nil
    /// 当日记录到的最高电池温度（°C，合法域 -20...100）
    var peakTemperatureC: Double? = nil
    /// `systemHealthPercent` 对应的真实 `system_profiler` 读取时刻（可选，向后兼容旧版台账）
    var systemHealthReadAt: Date? = nil

    var id: String { dayKey }

    static func maximumValidCapacity(forDesignCapacity designCapacityMah: Int) -> Int {
        guard designCapacityMah > 0 else { return 0 }
        return min(100_000, max(1, Int(Double(designCapacityMah) * 1.15)))
    }

    var isValid: Bool {
        guard schemaVersion == 1,
              Self.parseDayKey(dayKey, calendar: Self.validationCalendar) != nil,
              recordedAt.timeIntervalSince1970.isFinite,
              designCapacityMah > 0, designCapacityMah <= 100_000,
              cycleCount >= 0, cycleCount <= 10_000
        else { return false }

        let maxAllowedCapacity = Self.maximumValidCapacity(forDesignCapacity: designCapacityMah)

        if let health = systemHealthPercent {
            guard health.isFinite, health > 0, health <= 100 else { return false }
        }
        if let fcc = fullChargeCapacityMah {
            guard (1...maxAllowedCapacity).contains(fcc) else { return false }
        }
        if let nominal = nominalCapacityMah {
            guard (1...maxAllowedCapacity).contains(nominal) else { return false }
        }
        if let designCycle = designCycleCount {
            guard (1...10_000).contains(designCycle) else { return false }
        }
        if let temp = peakTemperatureC {
            guard temp.isFinite, temp >= -20, temp <= 100 else { return false }
        }
        if let healthReadAt = systemHealthReadAt {
            guard healthReadAt.timeIntervalSince1970.isFinite else { return false }
        }
        return true
    }

    /// FullChargeCapacity / DesignCapacity 百分比参考值；绝不写回 `systemHealthPercent`。
    var capacityRatioPercent: Double? {
        guard designCapacityMah > 0, let fcc = fullChargeCapacityMah, fcc > 0 else { return nil }
        return Double(fcc) / Double(designCapacityMah) * 100
    }

    func parsedDate(calendar: Calendar = .current) -> Date? {
        Self.parseDayKey(dayKey, calendar: calendar)
    }

    static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func parseDayKey(_ key: String, calendar: Calendar = .current) -> Date? {
        let bytes = Array(key.utf8)
        guard bytes.count == 10, bytes[4] == 0x2D, bytes[7] == 0x2D else { return nil }

        func digit(_ byte: UInt8) -> Int? {
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            return Int(byte - 0x30)
        }

        guard let y0 = digit(bytes[0]), let y1 = digit(bytes[1]),
              let y2 = digit(bytes[2]), let y3 = digit(bytes[3]),
              let m0 = digit(bytes[5]), let m1 = digit(bytes[6]),
              let d0 = digit(bytes[8]), let d1 = digit(bytes[9])
        else { return nil }

        let year = y0 * 1000 + y1 * 100 + y2 * 10 + y3
        let month = m0 * 10 + m1
        let day = d0 * 10 + d1
        guard year >= 1900, (1...12).contains(month), (1...31).contains(day) else { return nil }

        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        let roundTrip = calendar.dateComponents([.year, .month, .day], from: date)
        guard roundTrip.year == year, roundTrip.month == month, roundTrip.day == day else { return nil }
        return calendar.startOfDay(for: date)
    }

    private static let validationCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
}

enum HealthTrendMetric: String, CaseIterable, Identifiable, Sendable {
    case healthPercent = "健康度"
    case capacityMah = "满充容量"
    case cycleCount = "循环次数"

    var id: Self { self }
}

enum HealthTrendRange: String, CaseIterable, Identifiable, Sendable {
    case days30 = "30天"
    case days90 = "90天"
    case year1 = "1年"
    case all = "全部"

    var id: Self { self }
}

struct BatteryHealthTrendSummary: Equatable, Sendable {
    var recordCount: Int
    var spanDays: Int
    var startHealthPercent: Double?
    var endHealthPercent: Double?
    var healthDeltaPercent: Double?
    var startCapacityMah: Int?
    var endCapacityMah: Int?
    var capacityDeltaMah: Int?
    var startCycleCount: Int?
    var endCycleCount: Int?
    var cycleDelta: Int?
    var designCapacityMah: Int?
    var designCycleCount: Int?
}

/// 纯函数健康趋势分析：筛选时间窗口、计算区间变化摘要与图表纵轴域；
/// 绝不基于少量样本做虚假的电池剩余寿命外推。
enum BatteryHealthTrendAnalysis {
    static func defaultRange(
        for records: [BatteryHealthRecord],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> HealthTrendRange {
        let sorted = records.filter(\.isValid).sorted { $0.dayKey < $1.dayKey }
        guard sorted.count >= 2,
              let firstDate = sorted.first?.parsedDate(calendar: calendar),
              let lastDate = sorted.last?.parsedDate(calendar: calendar)
        else { return .all }

        let span = max(0, calendar.dateComponents([.day], from: firstDate, to: lastDate).day ?? 0)
        guard span >= 30 else { return .all }
        return filtered(sorted, range: .days30, now: now, calendar: calendar).isEmpty ? .all : .days30
    }

    static func filtered(
        _ records: [BatteryHealthRecord],
        range: HealthTrendRange,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> [BatteryHealthRecord] {
        let sorted = records.filter(\.isValid).sorted { $0.dayKey < $1.dayKey }
        let dayOffset: Int?
        switch range {
        case .days30: dayOffset = -29
        case .days90: dayOffset = -89
        case .year1: dayOffset = -364
        case .all: dayOffset = nil
        }

        guard let dayOffset else { return sorted }
        let today = calendar.startOfDay(for: now)
        guard let cutoff = calendar.date(byAdding: .day, value: dayOffset, to: today) else {
            return sorted
        }
        return sorted.filter { record in
            guard let date = record.parsedDate(calendar: calendar) else { return false }
            return date >= cutoff && date <= today
        }
    }

    static func summarize(
        _ records: [BatteryHealthRecord],
        calendar: Calendar = .current
    ) -> BatteryHealthTrendSummary {
        let sorted = records.filter(\.isValid).sorted { $0.dayKey < $1.dayKey }
        guard !sorted.isEmpty else {
            return BatteryHealthTrendSummary(
                recordCount: 0,
                spanDays: 0,
                startHealthPercent: nil,
                endHealthPercent: nil,
                healthDeltaPercent: nil,
                startCapacityMah: nil,
                endCapacityMah: nil,
                capacityDeltaMah: nil,
                startCycleCount: nil,
                endCycleCount: nil,
                cycleDelta: nil,
                designCapacityMah: nil,
                designCycleCount: nil
            )
        }

        let spanDays: Int
        if sorted.count >= 2,
           let firstDate = sorted.first?.parsedDate(calendar: calendar),
           let lastDate = sorted.last?.parsedDate(calendar: calendar) {
            spanDays = max(0, calendar.dateComponents([.day], from: firstDate, to: lastDate).day ?? 0)
        } else {
            spanDays = 0
        }

        let healthValues = sorted.compactMap(\.systemHealthPercent)
        let startHealth = healthValues.first
        let endHealth = healthValues.last
        let healthDelta: Double? = if healthValues.count >= 2, let startHealth, let endHealth {
            endHealth - startHealth
        } else {
            nil
        }

        let capacityValues = sorted.compactMap(\.fullChargeCapacityMah)
        let startCapacity = capacityValues.first
        let endCapacity = capacityValues.last
        let capacityDelta: Int? = if capacityValues.count >= 2, let startCapacity, let endCapacity {
            endCapacity - startCapacity
        } else {
            nil
        }

        let startCycle = sorted.first?.cycleCount
        let endCycle = sorted.last?.cycleCount
        let cycleDelta: Int? = if sorted.count >= 2, let startCycle, let endCycle {
            endCycle - startCycle
        } else {
            nil
        }

        return BatteryHealthTrendSummary(
            recordCount: sorted.count,
            spanDays: spanDays,
            startHealthPercent: startHealth,
            endHealthPercent: endHealth,
            healthDeltaPercent: healthDelta,
            startCapacityMah: startCapacity,
            endCapacityMah: endCapacity,
            capacityDeltaMah: capacityDelta,
            startCycleCount: startCycle,
            endCycleCount: endCycle,
            cycleDelta: cycleDelta,
            designCapacityMah: sorted.last?.designCapacityMah,
            designCycleCount: sorted.last(where: { $0.designCycleCount != nil })?.designCycleCount
        )
    }

    static func healthPercentDomain(_ records: [BatteryHealthRecord]) -> ClosedRange<Double> {
        let valid = records.filter(\.isValid)
        var values: [Double] = []
        values.reserveCapacity(valid.count * 2)
        for record in valid {
            if let health = record.systemHealthPercent {
                values.append(health)
            }
            if let ratio = record.capacityRatioPercent, ratio.isFinite {
                values.append(min(100, max(0, ratio)))
            }
        }
        guard let minVal = values.min(), let maxVal = values.max() else {
            return 80...100
        }

        var lower = max(0, floor(minVal - 4))
        var upper = min(100, ceil(maxVal + 3))
        if lower > upper {
            lower = upper
        }
        if upper - lower < 10 {
            let needed = 10 - (upper - lower)
            let addUp = min(100 - upper, ceil(needed / 2))
            upper += addUp
            let remaining = 10 - (upper - lower)
            lower = max(0, lower - remaining)
            if upper - lower < 10 {
                upper = min(100, lower + 10)
            }
        }
        return lower...upper
    }

    static func capacityDomain(_ records: [BatteryHealthRecord]) -> ClosedRange<Double> {
        let valid = records.filter(\.isValid)
        var values: [Double] = []
        values.reserveCapacity(valid.count * 3)
        for record in valid {
            values.append(Double(record.designCapacityMah))
            if let fcc = record.fullChargeCapacityMah {
                values.append(Double(fcc))
            }
            if let nominal = record.nominalCapacityMah {
                values.append(Double(nominal))
            }
        }
        guard let minVal = values.min(), let maxVal = values.max() else {
            return 0...5_000
        }

        let span = max(0, maxVal - minVal)
        let padding = max(200.0, ceil(span * 0.15 / 50.0) * 50.0)
        let lower = max(0, floor((minVal - padding) / 100.0) * 100.0)
        let upper = max(lower + 200.0, ceil((maxVal + padding) / 100.0) * 100.0)
        return lower...upper
    }

    static func cycleDomain(_ records: [BatteryHealthRecord]) -> ClosedRange<Double> {
        let valid = records.filter(\.isValid)
        let values = valid.map { Double($0.cycleCount) }
        guard let minVal = values.min(), let maxVal = values.max() else {
            return 0...50
        }

        let span = max(0, maxVal - minVal)
        let padding = max(5.0, ceil(span * 0.15))
        let lower = max(0, floor(minVal - padding))
        let upper = max(lower + 10.0, ceil(maxVal + padding))
        return lower...upper
    }
}
