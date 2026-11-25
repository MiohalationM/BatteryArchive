import Foundation
import Testing
@testable import BatteryArchive

/// 范围统计纯函数测试：
/// - 总覆盖率分母 = 用户所选范围的墙钟时长，完全缺失的分钟计为未覆盖；
/// - 按 aggregateWindowStart 去重并限制到所选窗口；
/// - 能耗只累加覆盖达标分钟的 systemEnergyWh。
@Suite struct RangeStatisticsTests {

    private let rangeStart = Date(timeIntervalSince1970: 1_800_000_000)

    private func aggregateSnapshot(
        windowStart: Date,
        coverage: Double,
        energyWh: Double? = 0.1
    ) -> BatterySnapshot {
        var snap = BatterySnapshot(
            timestamp: windowStart,
            level: 50, isCharging: false, wattage: 5,
            externalConnected: false
        )
        snap.aggregateWindowStart = windowStart
        snap.systemCoverage = coverage
        snap.systemEnergyWh = energyWh
        return snap
    }

    /// 六小时范围只有一个完整分钟 → 覆盖率 ≈ 1/360
    @Test func sixHourRangeWithOneFullMinuteIsOneOver360() {
        let rangeEnd = rangeStart.addingTimeInterval(6 * 3600)
        let coverage = RangeStatistics.overallSystemCoverage(
            snapshots: [aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(600), coverage: 1)],
            rangeStart: rangeStart, rangeEnd: rangeEnd
        )
        #expect(abs(coverage - 1.0 / 360.0) < 1e-9)
    }

    /// 一小时范围 60 个完整分钟 → 100%
    @Test func oneHourRangeWithSixtyFullMinutesIsFullyCovered() {
        let rangeEnd = rangeStart.addingTimeInterval(3600)
        let snaps = (0..<60).map { minute in
            aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(TimeInterval(minute * 60)), coverage: 1)
        }
        #expect(RangeStatistics.overallSystemCoverage(snapshots: snaps, rangeStart: rangeStart, rangeEnd: rangeEnd) == 1)
    }

    /// 中间缺口必须降低覆盖率（部分覆盖的分钟只按其 coverage 计入）
    @Test func middleGapReducesCoverage() {
        let rangeEnd = rangeStart.addingTimeInterval(3600)
        // 前 30 分钟满覆盖，第 31 分钟半覆盖，其余缺失
        var snaps = (0..<30).map { minute in
            aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(TimeInterval(minute * 60)), coverage: 1)
        }
        snaps.append(aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(1800), coverage: 0.5))
        let coverage = RangeStatistics.overallSystemCoverage(snapshots: snaps, rangeStart: rangeStart, rangeEnd: rangeEnd)
        #expect(abs(coverage - (30 + 0.5) / 60.0) < 1e-9)
    }

    /// 窗口外的聚合点不计入；同窗口重复点去重不双计
    @Test func outOfRangeAndDuplicateWindowsExcluded() {
        let rangeEnd = rangeStart.addingTimeInterval(600)
        let inside = aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(120), coverage: 1)
        let duplicate = aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(120), coverage: 1)
        let before = aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(-600), coverage: 1)
        let after = aggregateSnapshot(windowStart: rangeEnd, coverage: 1)
        let coverage = RangeStatistics.overallSystemCoverage(
            snapshots: [inside, duplicate, before, after],
            rangeStart: rangeStart, rangeEnd: rangeEnd
        )
        // 只有 1 个有效窗口 ×60s / 600s
        #expect(abs(coverage - 0.1) < 1e-9)
    }

    /// 能耗仅累加覆盖达标分钟；负能量/畸形值防御
    @Test func trustedEnergyOnlyFromQualifiedCoverage() {
        let rangeEnd = rangeStart.addingTimeInterval(600)
        let good = aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(60), coverage: 1, energyWh: 0.1667)
        let sparse = aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(120), coverage: 0.5, energyWh: 99)
        let negative = aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(180), coverage: 1, energyWh: -3)
        let outside = aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(-60), coverage: 1, energyWh: 42)
        let energy = RangeStatistics.trustedSystemEnergyWh(
            snapshots: [good, sparse, negative, outside], rangeStart: rangeStart, rangeEnd: rangeEnd
        )
        #expect(abs(energy - 0.1667) < 1e-9)
    }

    /// 48 秒达标分钟（coverage = 0.8）的有效时长为 48.0 秒（显示为 "<1m"），
    /// 并验证同窗口按高覆盖率优先、同覆盖率按较晚 timestamp 去重与均值/峰值/低值计算。
    @Test func systemPowerSummaryUsesExactEffectiveSecondsAndDeduplicatesWindows() throws {
        let rangeEnd = rangeStart.addingTimeInterval(600)

        var single = aggregateSnapshot(
            windowStart: rangeStart.addingTimeInterval(60),
            coverage: 0.8,
            energyWh: 10.0 * 48.0 / 3600.0
        )
        single.systemPowerAverage = 10
        single.systemPowerPeak = 14
        let singleSummary = try #require(RangeStatistics.systemPowerSummary(
            snapshots: [single], rangeStart: rangeStart, rangeEnd: rangeEnd
        ))
        #expect(singleSummary.usableMinuteCount == 1)
        #expect(abs(singleSummary.effectiveSeconds - 48.0) < 1e-9)
        #expect(UsageTimeFormat.duration(singleSummary.effectiveSeconds) == "<1m")
        #expect(abs(singleSummary.averageWatts - 10.0) < 1e-9)
        #expect(abs(singleSummary.peakWatts - 14.0) < 1e-9)
        #expect(singleSummary.lowWatts == 10)

        // 同窗口冲突：更高 coverage 优先；同 coverage 取较晚 timestamp
        let w1 = rangeStart.addingTimeInterval(60)
        var w1LowCov = aggregateSnapshot(windowStart: w1, coverage: 0.8, energyWh: 99)
        w1LowCov.systemPowerAverage = 99
        w1LowCov.systemPowerPeak = 99

        var w1HighEarly = aggregateSnapshot(windowStart: w1, coverage: 1.0, energyWh: 50)
        w1HighEarly.timestamp = w1.addingTimeInterval(55)
        w1HighEarly.systemPowerAverage = 50
        w1HighEarly.systemPowerPeak = 50

        var w1HighLate = aggregateSnapshot(windowStart: w1, coverage: 1.0, energyWh: 12.0 * 60.0 / 3600.0)
        w1HighLate.timestamp = w1.addingTimeInterval(60)
        w1HighLate.systemPowerAverage = 12
        w1HighLate.systemPowerPeak = 18

        let w2 = rangeStart.addingTimeInterval(120)
        var w2Good = aggregateSnapshot(windowStart: w2, coverage: 0.8, energyWh: 6.0 * 48.0 / 3600.0)
        w2Good.systemPowerAverage = 6
        w2Good.systemPowerPeak = 8

        var belowThreshold = aggregateSnapshot(windowStart: rangeStart.addingTimeInterval(180), coverage: 0.79, energyWh: 99)
        belowThreshold.systemPowerAverage = 99
        var outOfRange = aggregateSnapshot(windowStart: rangeEnd, coverage: 1.0, energyWh: 99)
        outOfRange.systemPowerAverage = 99

        let multiSummary = try #require(RangeStatistics.systemPowerSummary(
            snapshots: [w1LowCov, w1HighLate, w1HighEarly, w2Good, belowThreshold, outOfRange],
            rangeStart: rangeStart,
            rangeEnd: rangeEnd
        ))
        #expect(multiSummary.usableMinuteCount == 2)
        #expect(abs(multiSummary.effectiveSeconds - 108.0) < 1e-9)
        let expectedAvg = (12.0 * 60.0 + 6.0 * 48.0) / 108.0
        #expect(abs(multiSummary.averageWatts - expectedAvg) < 1e-9)
        #expect(abs(multiSummary.peakWatts - 18.0) < 1e-9)
        #expect(multiSummary.lowWatts == 6)
    }
}

/// 健康口径选择反例：系统值永远优先；容量比只是估算回退；全缺不可用。
@Suite struct BatteryHealthResolutionTests {

    private let readAt = Date(timeIntervalSince1970: 1_800_000_000)

    private func systemReading(_ percent: Double) -> SystemHealthReading {
        .init(percent: percent, readAt: readAt)
    }

    /// system_profiler fixture "98%" 解析为 98；畸形输入返回 nil 不默认 100
    @Test func systemProfilerFixtureParsing() {
        let json: [String: Any] = [
            "SPPowerDataType": [
                ["sppower_battery_health_info": ["sppower_battery_health_maximum_capacity": "98%"]]
            ]
        ]
        #expect(BatteryHealthMetric.systemProfilerHealthPercent(json: json) == 98)

        let missingValue: [String: Any] = [
            "SPPowerDataType": [["sppower_battery_health_info": [:]]]
        ]
        #expect(BatteryHealthMetric.systemProfilerHealthPercent(json: missingValue) == nil)

        let overRange: [String: Any] = [
            "SPPowerDataType": [
                ["sppower_battery_health_info": ["sppower_battery_health_maximum_capacity": "150%"]]
            ]
        ]
        #expect(BatteryHealthMetric.systemProfilerHealthPercent(json: overRange) == nil)
    }

    /// 系统值 98 与原始容量比 96.3 并存 → 选 98 且 source=system
    @Test func systemValueWinsOverRawCapacityRatio() {
        let resolved = BatteryHealthMetric.resolved(
            systemReading: SystemHealthReading(percent: 98, readAt: readAt),
            maxCapacityMah: 4220,
            designCapacityMah: 4382
        )
        #expect(resolved.percent == 98)
        #expect(resolved.sourceIsSystem)
        #expect(resolved.sourceLabel == "系统最大容量")
    }

    /// 系统值缺失 → 回退容量比估算（96.3%）并标注
    @Test func missingSystemValueFallsBackToRatioEstimate() {
        let resolved = BatteryHealthMetric.resolved(
            systemReading: nil,
            maxCapacityMah: 4220,
            designCapacityMah: 4382
        )
        #expect(abs(resolved.percent - (Double(4220) / Double(4382) * 100)) < 1e-9)
        #expect(!resolved.sourceIsSystem)
        #expect(resolved.sourceLabel == "容量比估算")
    }

    /// 全部缺失 → 不可用（percent=0），不默认 100
    @Test func allMissingMeansUnavailableNotHundred() {
        let resolved = BatteryHealthMetric.resolved(
            systemReading: nil, maxCapacityMah: 0, designCapacityMah: 4382
        )
        #expect(resolved.percent == 0)
        #expect(resolved.sourceLabel == nil)
    }

    /// 健康刷新 TTL 决策：未取过→刷新；TTL 内→不刷新；到期→刷新
    @Test func healthRefreshTTLCadence() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ttl: TimeInterval = 3600
        #expect(BatteryHealthMetric.shouldRefresh(lastFetchAt: nil, now: now, ttl: ttl))
        #expect(!BatteryHealthMetric.shouldRefresh(lastFetchAt: now.addingTimeInterval(-1800), now: now, ttl: ttl))
        #expect(BatteryHealthMetric.shouldRefresh(lastFetchAt: now.addingTimeInterval(-3601), now: now, ttl: ttl))
    }
}
