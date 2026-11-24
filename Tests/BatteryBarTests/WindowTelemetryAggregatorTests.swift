import Foundation
import Testing
@testable import BatteryBar

/// 分钟聚合器反例（冻结口径）：
/// - 零阶保持积分，单样本最多保持 min(30s, 2×预期间隔)，缺口不外推；
/// - 有效零瓦计入覆盖率，缺失不计入；
/// - 充入/放出方向严格分开；来源未知排除；
/// - 温度按有效时长加权平均；乱序拒绝；睡眠立即截断。
@Suite struct WindowTelemetryAggregatorTests {

    /// 窗口起点对齐 Unix 纪元的整分钟，便于构造观测时间
    private let w0 = Date(timeIntervalSince1970: 1_800_000_000) // 整分钟

    private func aggregate(
        _ aggregator: inout WindowTelemetryAggregator,
        at date: Date,
        load: Double? = nil,
        channel: WindowTelemetryAggregator.BatteryChannel = .unknown,
        temperature: Double? = nil,
        interval: TimeInterval = 15
    ) {
        aggregator.observe(WindowTelemetryAggregator.Observation(
            date: date,
            trustedSystemLoad: load,
            batteryChannel: channel,
            temperatureCelsius: temperature,
            expectedInterval: interval
        ))
    }

    @Test func tenWattsForFullMinuteIsOneSixthWh() throws {
        var agg = WindowTelemetryAggregator()
        let exp15 = 15.0 // hold 30s，链式覆盖整分钟
        aggregate(&agg, at: w0, load: 10, interval: exp15)
        aggregate(&agg, at: w0.addingTimeInterval(20), load: 10)
        aggregate(&agg, at: w0.addingTimeInterval(40), load: 10)
        aggregate(&agg, at: w0.addingTimeInterval(60), load: 10) // 触发窗口收尾

        let minuteOpt = agg.takeCompletedAggregate()
        let minute = try #require(minuteOpt)
        #expect(minute.windowStart == w0)
        #expect(abs(minute.systemEnergyWh! - 10.0 * 60.0 / 3600.0) < 1e-9)
        #expect(abs(minute.systemPowerAverage! - 10) < 1e-9)
        #expect(minute.systemPowerPeak == 10)
        #expect(abs(minute.systemCoverage - 1) < 1e-9)
    }

    @Test func thirtySecondsAtTenThenThirtyAtTwentyAveragesFifteen() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 10)
        aggregate(&agg, at: w0.addingTimeInterval(30), load: 20)
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteOpt = agg.takeCompletedAggregate()
        let minute = try #require(minuteOpt)
        #expect(abs(minute.systemEnergyWh! - 0.25) < 1e-9)
        #expect(abs(minute.systemPowerAverage! - 15) < 1e-9)
        #expect(minute.systemPowerPeak == 20)
    }

    /// 单样本最多保持 30 秒：之后是缺口，严禁外推到窗口末端
    @Test func holdExpiresAfterThirtySecondsNoExtrapolation() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 10, interval: 15)          // hold 到 w0+30
        aggregate(&agg, at: w0.addingTimeInterval(90))           // 跨边界触发收尾

        let minuteOpt = agg.takeCompletedAggregate()
        let minute = try #require(minuteOpt)
        #expect(abs(minute.systemEnergyWh! - 10.0 * 30.0 / 3600.0) < 1e-9)
        #expect(abs(minute.systemCoverage - 0.5) < 1e-9)
        #expect(minute.hasFullSystemMetric == false)
    }

    /// 接电充电功率不得进入系统能耗：无可信系统负载时 systemEnergy 为空，
    /// 充电时长只计入电池充入侧，绝不污染放电侧。
    @Test func chargingPowerNeverEntersSystemEnergy() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: nil, channel: .charge(25))
        aggregate(&agg, at: w0.addingTimeInterval(30), channel: .charge(25))
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteOpt = agg.takeCompletedAggregate()
        let minute = try #require(minuteOpt)
        #expect(minute.systemEnergyWh == nil)
        #expect(minute.systemCoverage == 0)
        #expect(minute.batteryDischargeWh == 0)
        #expect(minute.batteryDischargeSeconds == 0)
        #expect(abs(minute.batteryChargeSeconds - 60) < 1e-9)
    }

    /// 充入/放出严格分开；来源未知两侧都不进
    @Test func chargeAndDischargeStaySeparateUnknownExcluded() throws {
        var chargeOnly = WindowTelemetryAggregator()
        aggregate(&chargeOnly, at: w0, channel: .charge(8))
        aggregate(&chargeOnly, at: w0.addingTimeInterval(60))
        let chargeOpt = chargeOnly.takeCompletedAggregate()
        let chargeMinute = try #require(chargeOpt)
        #expect(chargeMinute.batteryChargeSeconds > 0 && chargeMinute.batteryDischargeWh == 0)

        var unknown = WindowTelemetryAggregator()
        aggregate(&unknown, at: w0, channel: .unknown)
        aggregate(&unknown, at: w0.addingTimeInterval(60))
        let unknownOpt = unknown.takeCompletedAggregate()
        let unknownMinute = try #require(unknownOpt)
        #expect(unknownMinute.batteryDischargeWh == 0)
        #expect(unknownMinute.batteryChargeSeconds == 0)
        #expect(unknownMinute.batteryDischargeSeconds == 0)

        var dischargeOnly = WindowTelemetryAggregator()
        aggregate(&dischargeOnly, at: w0, channel: .discharge(6))
        aggregate(&dischargeOnly, at: w0.addingTimeInterval(60))
        let dischargeOpt = dischargeOnly.takeCompletedAggregate()
        let dischargeMinute = try #require(dischargeOpt)
        #expect(dischargeMinute.batteryChargeSeconds == 0 && dischargeMinute.batteryDischargeWh > 0)
    }

    /// 20°C 30 秒 + 40°C 30 秒：加权平均 30°C、最高 40°C
    @Test func temperatureWeightedAverageAndMaximum() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, temperature: 20)
        aggregate(&agg, at: w0.addingTimeInterval(30), temperature: 40)
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteOpt = agg.takeCompletedAggregate()
        let minute = try #require(minuteOpt)
        #expect(abs(minute.temperatureAverage! - 30) < 1e-9)
        #expect(minute.temperatureMaximum == 40)
        #expect(abs(minute.temperatureCoverage - 1) < 1e-9)
    }

    /// 有效零瓦必须计入覆盖率；缺失不计入
    @Test func validZeroWattCountsTowardCoverageGapDoesNot() throws {
        var zero = WindowTelemetryAggregator()
        aggregate(&zero, at: w0, load: 0)
        aggregate(&zero, at: w0.addingTimeInterval(30), load: 0)
        aggregate(&zero, at: w0.addingTimeInterval(60))
        let zeroOpt = zero.takeCompletedAggregate()
        let zeroMinute = try #require(zeroOpt)
        #expect(zeroMinute.systemEnergyWh == 0)
        #expect(zeroMinute.systemPowerAverage == 0)
        #expect(abs(zeroMinute.systemCoverage - 1) < 1e-9)

        var gap = WindowTelemetryAggregator()
        aggregate(&gap, at: w0, load: nil)
        aggregate(&gap, at: w0.addingTimeInterval(30), load: nil)
        aggregate(&gap, at: w0.addingTimeInterval(60))
        let gapOpt = gap.takeCompletedAggregate()
        let gapMinute = try #require(gapOpt)
        #expect(gapMinute.systemEnergyWh == nil)
        #expect(gapMinute.systemCoverage == 0)
    }

    /// 乱序/负时间整条观测拒绝
    @Test func outOfOrderObservationRejected() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0.addingTimeInterval(50), load: 10)
        aggregate(&agg, at: w0.addingTimeInterval(20), load: 100)
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteOpt = agg.takeCompletedAggregate()
        let minute = try #require(minuteOpt)
        #expect(abs(minute.systemEnergyWh! - 10.0 * 10.0 / 3600.0) < 1e-9)
        #expect(minute.systemPowerPeak == 10)
    }

    /// 睡眠开始立即截断连续量：睡前功率不延伸进睡眠区间
    @Test func sleepTruncatesContinuityImmediately() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 10)
        agg.truncateContinuity(at: w0.addingTimeInterval(25))
        aggregate(&agg, at: w0.addingTimeInterval(95), load: 12)

        let firstOpt = agg.takeCompletedAggregate()
        let firstWindow = try #require(firstOpt)
        #expect(firstWindow.windowStart == w0)
        #expect(abs(firstWindow.systemEnergyWh! - 10.0 * 25.0 / 3600.0) < 1e-9)
    }

    /// 前后台节奏切换改变保持上限（5s→10s，15s→30s）
    @Test func foregroundBackgroundSwitchChangesHoldLimit() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 10, interval: 5)           // hold 10s
        aggregate(&agg, at: w0.addingTimeInterval(20), load: 10, interval: 15)  // hold 30s
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteOpt = agg.takeCompletedAggregate()
        let minute = try #require(minuteOpt)
        let expectedSeconds: TimeInterval = 10 + 30
        #expect(abs(minute.systemEnergyWh! - 10.0 * expectedSeconds / 3600.0) < 1e-9)
        #expect(abs(minute.systemCoverage - expectedSeconds / 60.0) < 1e-9)
    }

    /// 完全缺失的分钟不生成空窗口；有界队列按时间升序保留真实经过的分钟
    @Test func skippedMinutesProduceNoEmptyWindows() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, load: 5)
        // 直接跳到第三分钟：第二分钟从未存在
        aggregate(&agg, at: w0.addingTimeInterval(125), load: 5)
        aggregate(&agg, at: w0.addingTimeInterval(185), load: 5)

        let completed = agg.takeCompletedAggregates()
        #expect(completed.map(\.windowStart) == [w0, w0.addingTimeInterval(120)])
        let remaining = agg.takeCompletedAggregates()
        #expect(remaining.isEmpty)
    }

    /// 来源明确的真实 0W 放电：正确方向覆盖增加、Wh=0
    @Test func validZeroWattDischargeAccumulatesCoverageOnly() throws {
        var agg = WindowTelemetryAggregator()
        aggregate(&agg, at: w0, channel: .discharge(0))
        aggregate(&agg, at: w0.addingTimeInterval(30), channel: .discharge(0))
        aggregate(&agg, at: w0.addingTimeInterval(60))

        let minuteOpt = agg.takeCompletedAggregate()
        let minute = try #require(minuteOpt)
        #expect(abs(minute.batteryDischargeSeconds - 60) < 1e-9)
        #expect(minute.batteryDischargeWh == 0)
        #expect(minute.batteryChargeSeconds == 0)
    }
}
