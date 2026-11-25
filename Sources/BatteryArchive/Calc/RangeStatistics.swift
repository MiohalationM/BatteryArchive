import Foundation

/// 所选范围内系统负载分钟聚合的共享摘要结果（供功耗页与概览页统一消费）。
struct SystemPowerRangeSummary: Equatable, Sendable {
    var averageWatts: Double
    var peakWatts: Double
    var lowWatts: Double?
    var usableMinuteCount: Int
    var effectiveSeconds: TimeInterval
}

/// 功耗页范围统计的纯函数（无 SwiftUI 依赖，可独立反例测试）。
enum RangeStatistics {

    /// 所选范围内达标分钟聚合的系统负载摘要：
    /// - 限制 `aggregateWindowStart` 落在 `[rangeStart, rangeEnd)` 内；
    /// - 按 `aggregateWindowStart` 去重（优先更高覆盖率，覆盖率相同时优先较晚 `timestamp`）；
    /// - 过滤 `systemCoverage >= coverageThreshold` 且 `systemPowerAverage` 有限、`systemEnergyWh` 有限非负的分钟；
    /// - `effectiveSeconds = sum(min(1, max(0, cov)) * 60)`，与真实有效积分时长严格一致。
    static func systemPowerSummary(
        snapshots: [BatterySnapshot],
        rangeStart: Date,
        rangeEnd: Date,
        coverageThreshold: Double = 0.8
    ) -> SystemPowerRangeSummary? {
        guard rangeEnd > rangeStart else { return nil }
        var bestByWindow: [Date: BatterySnapshot] = [:]
        for snap in snapshots {
            guard let windowStart = snap.aggregateWindowStart,
                  windowStart >= rangeStart, windowStart < rangeEnd,
                  let coverage = snap.systemCoverage, coverage.isFinite, coverage >= coverageThreshold,
                  let avg = snap.systemPowerAverage, avg.isFinite,
                  let wh = snap.systemEnergyWh, wh.isFinite, wh >= 0
            else { continue }
            if let existing = bestByWindow[windowStart] {
                let existingCov = existing.systemCoverage ?? 0
                if coverage < existingCov { continue }
                if coverage == existingCov, snap.timestamp < existing.timestamp { continue }
            }
            bestByWindow[windowStart] = snap
        }
        guard !bestByWindow.isEmpty else { return nil }

        var totalEnergy = 0.0
        var effectiveSeconds = 0.0
        var maxPeak = 0.0
        var minAvg: Double?
        for snap in bestByWindow.values {
            let cov = min(1, max(0, snap.systemCoverage ?? 0))
            totalEnergy += snap.systemEnergyWh ?? 0
            effectiveSeconds += cov * 60
            if let peak = snap.systemPowerPeak, peak.isFinite {
                maxPeak = max(maxPeak, peak)
            }
            if let avg = snap.systemPowerAverage, avg.isFinite {
                minAvg = minAvg.map { min($0, avg) } ?? avg
            }
        }
        let effectiveHours = effectiveSeconds / 3600
        guard effectiveHours > 0 else { return nil }
        let averageWatts = totalEnergy / effectiveHours
        return SystemPowerRangeSummary(
            averageWatts: averageWatts,
            peakWatts: max(maxPeak, averageWatts),
            lowWatts: minAvg,
            usableMinuteCount: bestByWindow.count,
            effectiveSeconds: effectiveSeconds
        )
    }

    /// 所选范围的总覆盖率计算规则：
    /// - 分母是用户选择范围的墙钟时长（rangeStart→rangeEnd），
    ///   不是现存聚合点数量；
    /// - 完全缺失的分钟计为未覆盖；
    /// - 按 aggregateWindowStart 去重并限制到所选窗口；
    /// - 每分钟贡献 min(coverage,1)×60 秒，结果裁到 0...1。
    static func overallSystemCoverage(
        snapshots: [BatterySnapshot],
        rangeStart: Date,
        rangeEnd: Date
    ) -> Double {
        let total = rangeEnd.timeIntervalSince(rangeStart)
        guard total > 0 else { return 0 }
        var bestCoverageByWindow: [Date: Double] = [:]
        for snap in snapshots {
            guard let windowStart = snap.aggregateWindowStart,
                  windowStart >= rangeStart, windowStart < rangeEnd
            else { continue }
            let raw = snap.systemCoverage ?? 0
            let clamped = raw.isFinite ? min(1, max(0, raw)) : 0
            if let existing = bestCoverageByWindow[windowStart], existing >= clamped {
                continue
            }
            bestCoverageByWindow[windowStart] = clamped
        }
        let coveredSeconds = bestCoverageByWindow.values.reduce(0.0) { $0 + $1 * 60 }
        return min(1, max(0, coveredSeconds / total))
    }

    /// 所选范围内的可信能耗合计：仅累加覆盖达标（≥0.8）的 systemEnergyWh，
    /// 按 aggregateWindowStart 去重并限制到所选窗口；同窗口多条记录优先取覆盖率更高的达标项。
    static func trustedSystemEnergyWh(
        snapshots: [BatterySnapshot],
        rangeStart: Date,
        rangeEnd: Date,
        coverageThreshold: Double = 0.8
    ) -> Double {
        var bestByWindow: [Date: (coverage: Double, wh: Double)] = [:]
        for snap in snapshots {
            guard let windowStart = snap.aggregateWindowStart,
                  windowStart >= rangeStart, windowStart < rangeEnd,
                  let coverage = snap.systemCoverage, coverage.isFinite, coverage >= coverageThreshold,
                  let wh = snap.systemEnergyWh, wh.isFinite, wh >= 0
            else { continue }
            if let existing = bestByWindow[windowStart], existing.coverage >= coverage {
                continue
            }
            bestByWindow[windowStart] = (coverage, wh)
        }
        return bestByWindow.values.reduce(0.0) { $0 + $1.wh }
    }
}
