import Foundation
import Testing
@testable import BatteryBar

/// 续航与充电估算测试：
/// - Theil–Sen 中位斜率正确且抗电量回跳/异常点；
/// - 跨度、下降、覆盖不足必须返回数据不足（nil）；
/// - 接电与来源未知样本完全排除；
/// - 满充能量只来自真实容量×合理电压，电压缺失绝不采用 11.1V 默认值；
/// - 两路证据差异 >2 倍时总置信度下降；充电暂停/满电保持不显示估算。
@Suite struct RuntimeEstimatorTests {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ offsetSeconds: TimeInterval,
        _ level: Double,
        externalConnected: Bool? = false,
        isCharging: Bool = false
    ) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: t0.addingTimeInterval(offsetSeconds),
            level: level,
            isCharging: isCharging,
            wattage: 8,
            systemPowerAvailable: true,
            systemPowerIsEstimated: true,
            externalConnected: externalConnected
        )
    }

    /// 线性放电序列：每分钟掉 0.1%（=6%/h）
    private func linearDischarge(minutes: Int, startLevel: Double = 80) -> [BatterySnapshot] {
        (0...minutes).map { minute in
            snapshot(TimeInterval(minute * 60), startLevel - Double(minute) * 0.1)
        }
    }

    // MARK: A. 历史百分比斜率

    /// 20 分钟下降 2%：Theil–Sen 斜率 6%/h 的内部证据成立，
    /// 但 confidence≈0.333 低于展示门槛 0.40 —— dischargeEstimate 必须 nil。
    @Test func twentyMinuteTwoPercentDropYieldsSixPercentPerHour() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 78
        input.externalConnected = false
        input.snapshots = linearDischarge(minutes: 20)

        let evidence = try #require(RuntimeEstimator.historicalSlopeEvidence(input))
        #expect(abs(evidence.ratePercentPerHour - 6.0) < 0.01)
        #expect(evidence.basis == .historicalSlope)
        #expect(evidence.coverage >= 0.7)
        #expect(evidence.confidence >= 0.3 && evidence.confidence < RuntimeEstimator.minimumDisplayConfidence)

        // 单路出口同样执行门槛：证据存在 ≠ 可展示
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
    }

    /// 单个电量回跳/异常点不能摧毁中位斜率
    @Test func singleLevelSpikeDoesNotDestroyMedianSlope() throws {
        var snaps = linearDischarge(minutes: 20)
        snaps[10] = snapshot(600, 85)                        // 中段回跳 +5%
        snaps.remove(at: 11)

        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 77.9
        input.externalConnected = false
        input.snapshots = snaps

        let evidence = try #require(RuntimeEstimator.historicalSlopeEvidence(input))
        #expect(abs(evidence.ratePercentPerHour - 6.0) < 0.35)
    }

    /// 跨度不足 / 净下降不足 / 覆盖不足：一律数据不足
    @Test func insufficientSpanDropOrCoverageReturnNil() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(900)
        input.currentLevel = 79
        input.externalConnected = false
        // 跨度只有 15 分钟
        input.snapshots = linearDischarge(minutes: 15)
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) == nil)

        // 净下降只有 1.5%
        input.now = t0.addingTimeInterval(1200)
        input.snapshots = (0...20).map { minute in
            snapshot(TimeInterval(minute * 60), 80 - Double(minute) * 0.075)
        }
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) == nil)

        // 大缺口导致覆盖率 <0.7
        var sparse = (0...10).map { minute in
            snapshot(TimeInterval(minute * 60), 80 - Double(minute) * 0.1)
        }
        sparse.append(contentsOf: (0...5).map { minute in
            snapshot(3300 + TimeInterval(minute * 60), 78 - Double(minute) * 0.1)
        })
        input.now = t0.addingTimeInterval(3600)
        input.snapshots = sparse
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) == nil)
    }

    /// 接电与来源未知会截断当前证据段，不能过滤掉后把前后拼接。
    @Test func pluggedAndUnknownSourceSamplesCutEvidenceEpisode() {
        var snaps = linearDischarge(minutes: 20)
        // 混入接电与来源未知点（其中包含更陡的假斜率）
        snaps[5] = snapshot(300, 79, externalConnected: true, isCharging: true)
        snaps[12] = snapshot(720, 76, externalConnected: nil)

        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 78
        input.externalConnected = false
        input.snapshots = snaps

        #expect(RuntimeEstimator.historicalSlopeEvidence(input) == nil)
    }

    // MARK: B. 电池功率证据

    private func dischargeAggregates(watts: Double, minutes: Int) -> [MinuteAggregate] {
        (0..<minutes).map { minute in
            MinuteAggregate(
                windowStart: t0.addingTimeInterval(TimeInterval(minute * 60)),
                systemEnergyWh: watts * 60 / 3600,
                systemPowerAverage: watts,
                systemPowerPeak: watts,
                systemCoverage: 1,
                batteryChargeSeconds: 0,
                batteryDischargeWh: watts * 60 / 3600,
                batteryDischargeSeconds: 60,
                temperatureAverage: 30,
                temperatureMaximum: 31,
                temperatureCoverage: 1
            )
        }
    }

    /// 5000mAh × 12V = 60Wh，平均 6W 对应 10%/h；50% 约 5 小时
    @Test func sixtyWhPackAtSixWattsIsTenPercentPerHour() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(900)
        input.currentLevel = 50
        input.externalConnected = false
        input.minuteAggregates = dischargeAggregates(watts: 6, minutes: 15)
        input.fullChargeCapacityMah = 5000
        input.voltageMV = 12_000

        let evidence = try #require(RuntimeEstimator.batteryPowerEvidence(input))
        #expect(abs(evidence.ratePercentPerHour - 10.0) < 0.01)
        #expect(evidence.confidence <= 0.66)                 // 瞬时电压只能中等置信度
        #expect(evidence.band == .medium)

        let estimate = try #require(RuntimeEstimator.dischargeEstimate(input))
        #expect(abs(estimate.valueHours - 5.0) < 0.01)
    }

    /// 电压缺失时绝不采用 11.1V 默认值——该路径整体不可用
    @Test func missingVoltageNeverFallsBackToDefault() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(900)
        input.currentLevel = 50
        input.externalConnected = false
        input.minuteAggregates = dischargeAggregates(watts: 6, minutes: 15)
        input.fullChargeCapacityMah = 5000
        input.voltageMV = 0                                  // 未知

        #expect(RuntimeEstimator.batteryPowerEvidence(input) == nil)

        input.voltageMV = 3_000                              // 荒谬电压：拒绝坏数据而非夹值
        #expect(RuntimeEstimator.batteryPowerEvidence(input) == nil)
    }

    // MARK: C. 融合与回退

    /// 两路证据差异 >2 倍且矛盾惩罚后低于门槛（≈0.298 < 0.40）→ 不展示
    @Test func contradictoryEvidenceBelowThresholdReturnsNil() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 60
        input.externalConnected = false
        input.snapshots = linearDischarge(minutes: 20)       // 斜率路径 6%/h，conf≈0.333
        input.minuteAggregates = dischargeAggregates(watts: 30, minutes: 15)
        for i in input.minuteAggregates.indices {
            input.minuteAggregates[i].windowStart = input.minuteAggregates[i].windowStart.addingTimeInterval(300)
        }
        input.fullChargeCapacityMah = 5000                   // 功率路径 50%/h（>2×6），conf 0.66
        input.voltageMV = 12_000

        // 两路内部证据都存在
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) != nil)
        #expect(RuntimeEstimator.batteryPowerEvidence(input) != nil)
        // 融合出口：((0.333+0.66)/2)×0.6 < 0.40 → nil
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
    }

    /// 置信度足够高的矛盾双路仍可展示：降置信与扩大区间可观察
    @Test func highConfidenceContradictionStaysObservable() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(3600)
        input.currentLevel = 75
        input.externalConnected = false
        // 60 分钟净下降 5%：斜率 5%/h，confidence=min(1,1,coverage)=1
        input.snapshots = (0...60).map { minute in
            snapshot(TimeInterval(minute * 60), 80 - Double(minute) * (5.0 / 60.0))
        }
        // 功率路径 50%/h（>2×5），confidence 0.66；15 个窗口必须全部落在
        // 最近 15 分钟内，否则功率证据因有效时长不足而缺席
        var longAggregates: [MinuteAggregate] = []
        for minute in 0..<15 {
            longAggregates.append(MinuteAggregate(
                windowStart: t0.addingTimeInterval(TimeInterval(2760 + minute * 60)),
                systemEnergyWh: 0.5,
                systemPowerAverage: 30,
                systemPowerPeak: 32,
                systemCoverage: 1,
                batteryChargeSeconds: 0,
                batteryDischargeWh: 0.5,
                batteryDischargeSeconds: 60,
                temperatureAverage: 30,
                temperatureMaximum: 31,
                temperatureCoverage: 1
            ))
        }
        input.minuteAggregates = longAggregates
        // 功率证据的满充能量口径：5000mAh × 12V = 60Wh
        input.fullChargeCapacityMah = 5000
        input.voltageMV = 12_000

        // 自诊断：先确认两路内部证据都在（若缺席，消息携带现场数据）
        let power = try #require(
            RuntimeEstimator.batteryPowerEvidence(input),
            "power evidence missing: aggregates=\(input.minuteAggregates.count) windows=\(input.minuteAggregates.map { $0.windowStart.timeIntervalSince1970 })"
        )
        #expect(power.confidence >= 0.6)
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) != nil)

        let fused = try #require(RuntimeEstimator.dischargeEstimate(input))
        #expect(fused.basis == .fused)
        // (1 + 0.66)/2 × 0.6 ≈ 0.498 ≥ 0.40 → 可展示但降置信
        #expect(fused.confidence >= RuntimeEstimator.minimumDisplayConfidence)
        #expect(fused.failureReason?.contains("差异") == true)
        // 矛盾扩大区间
        if let lower = fused.lowerHours, let upper = fused.upperHours {
            let spread = (upper - lower) / fused.valueHours
            #expect(spread > 0.5)
        } else {
            Issue.record("fused result missing interval bounds")
        }
    }

    /// 一致证据的融合置信度高于矛盾场景
    @Test func consistentEvidenceKeepsHigherConfidence() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 60
        input.externalConnected = false
        input.snapshots = linearDischarge(minutes: 20)       // 6%/h
        // 功率路径也给出 6%/h：60Wh × 10% = 6W
        input.minuteAggregates = dischargeAggregates(watts: 6, minutes: 15)
        for i in input.minuteAggregates.indices {
            input.minuteAggregates[i].windowStart = input.minuteAggregates[i].windowStart.addingTimeInterval(300)
        }
        input.fullChargeCapacityMah = 5000
        input.voltageMV = 12_000

        let fused = try #require(RuntimeEstimator.dischargeEstimate(input))
        #expect(fused.basis == .fused)
        #expect(fused.failureReason == nil)
        #expect(fused.band == .medium || fused.band == .high)
    }

    /// App 两路都不可用时返回 nil；系统剩余时间作为独立证据单独提供
    @Test func insufficientAppEvidenceReturnsNilButSystemReportedStaysSeparate() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(600)
        input.currentLevel = 50
        input.externalConnected = false
        input.snapshots = []
        input.minuteAggregates = []
        input.systemReportedMinutes = 300

        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
        let system = RuntimeEstimator.systemReportedEstimate(input)
        #expect(system != nil)
        #expect(system?.basis == .systemReported)
        // 系统证据永不与 App 证据融合：basis 恒为 systemReported
    }

    /// 明确接电或来源未知时不显示离电续航
    @Test func noOffPowerEstimateWhenPluggedOrUnknown() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 60
        input.snapshots = linearDischarge(minutes: 20)
        input.externalConnected = true
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)

        input.externalConnected = nil                        // 来源未知
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
        #expect(RuntimeEstimator.systemReportedEstimate(input) == nil)
    }

    // MARK: 充电估算

    /// 正常充电：30 分钟 +3%，中位斜率 6%/h，剩余时间标注按当前速度
    @Test func normalChargingProducesTimeToFull() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1800)
        input.currentLevel = 50
        input.isCharging = true
        input.externalConnected = true
        input.chargeTargetPercent = 100
        input.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 50 + Double(minute) * 0.1,
                     externalConnected: true, isCharging: true)
        }

        let estimate = try #require(RuntimeEstimator.chargeEstimate(input))
        #expect(abs(estimate.ratePercentPerHour - 6.0) < 0.01)
        #expect(abs(estimate.valueHours - 50.0 / 6.0) < 0.1)
        #expect(estimate.band != .high || estimate.confidence <= 1)
    }

    /// 充电暂停（isCharging=false）、满电保持、80% 上限无正增长：不显示时间
    @Test func pausedOrHeldChargingShowsNoEstimate() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1800)
        input.currentLevel = 80
        input.isCharging = false                             // 接电暂停/满电保持/上限
        input.externalConnected = true
        input.chargeTargetPercent = 80
        input.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 80, externalConnected: true, isCharging: false)
        }
        #expect(RuntimeEstimator.chargeEstimate(input) == nil)

        // 在充电但无正增长（满电保持抖动）
        input.isCharging = true
        input.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 80 + [0, 0.2, -0.1][minute % 3],
                     externalConnected: true, isCharging: true)
        }
        #expect(RuntimeEstimator.chargeEstimate(input) == nil)
    }

    /// 80% 以上涓流阶段置信度 ×0.6 后低于门槛（0.54→0.324）→ 不展示；
    /// 5 分钟仅增长 1% 的低置信充电证据（≈0.15）同样不展示；
    /// 200%/h 异常速率直接拒绝而不是夹值。
    @Test func tricklePhaseLowersConfidenceAndAbsurdRateRejected() throws {
        func chargingInput(level: Double) -> RuntimeEstimator.Inputs {
            var input = RuntimeEstimator.Inputs()
            input.now = t0.addingTimeInterval(1800)
            input.currentLevel = level
            input.isCharging = true
            input.externalConnected = true
            input.chargeTargetPercent = 100
            input.snapshots = (0...30).map { minute in
                snapshot(TimeInterval(minute * 60), level + Double(minute) * 0.1,
                         externalConnected: true, isCharging: true)
            }
            return input
        }

        // 正常速率（30 分钟 +3%，conf≈0.54 ≥ 0.40）可展示
        let normal = try #require(RuntimeEstimator.chargeEstimate(chargingInput(level: 50)))
        #expect(normal.confidence >= RuntimeEstimator.minimumDisplayConfidence)

        // 涓流阶段（level>85）：0.54×0.6 < 0.40 → nil
        #expect(RuntimeEstimator.chargeEstimate(chargingInput(level: 85)) == nil)

        // 低置信短窗口：5 分钟 +1%（斜率 12%/h 合法，但 conf≈0.15）
        var short = RuntimeEstimator.Inputs()
        short.now = t0.addingTimeInterval(300)
        short.currentLevel = 50
        short.isCharging = true
        short.externalConnected = true
        short.chargeTargetPercent = 100
        short.snapshots = (0...5).map { minute in
            snapshot(TimeInterval(minute * 60), 50 + Double(minute) * 0.2,
                     externalConnected: true, isCharging: true)
        }
        #expect(RuntimeEstimator.chargeEstimate(short) == nil)

        // 200%/h 的异常斜率直接拒绝（不再夹到 80）
        var absurd = chargingInput(level: 50)
        absurd.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 50 + Double(minute) * (200.0 / 60.0),
                     externalConnected: true, isCharging: true)
        }
        #expect(RuntimeEstimator.chargeEstimate(absurd) == nil)
    }

    /// 合盖睡眠充电：30 分钟仅首尾两条快照，覆盖率 ≈0.07 → 置信度跌破门槛，
    /// 不得显示「充满需 19 小时」（覆盖率下限 0.5 掩盖缺陷的回归反例）。
    @Test func sleepChargingWithSparseEndpointsReturnsNil() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1800)
        input.currentLevel = 43
        input.isCharging = true
        input.externalConnected = true
        input.chargeTargetPercent = 100
        input.snapshots = [
            snapshot(0, 40, externalConnected: true, isCharging: true),
            snapshot(1800, 43, externalConnected: true, isCharging: true),
        ]
        let evidence = RuntimeEstimator.chargeEstimate(input)
        #expect(evidence == nil)
    }

    @Test func configuredTargetReplacesFullChargeTargetWithoutChangingLevel() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1800)
        input.currentLevel = 79
        input.isCharging = true
        input.externalConnected = true
        input.chargeTargetPercent = 80
        input.snapshots = (0...30).map { minute in
            snapshot(TimeInterval(minute * 60), 76 + Double(minute) * 0.1,
                     externalConnected: true, isCharging: true)
        }

        let estimate = try #require(RuntimeEstimator.chargeEstimate(input))
        #expect(estimate.goalPercent == 80)
        #expect(abs(estimate.valueHours - 1.0 / 6.0) < 0.02)

        // 停充于79%时既没有到达80，也不显示倒计时；超过上限的真实电量不被重标。
        input.isCharging = false
        #expect(RuntimeEstimator.chargeEstimate(input) == nil)
        input.currentLevel = 81
        input.isCharging = true
        #expect(RuntimeEstimator.chargeEstimate(input) == nil)
        #expect(input.currentLevel == 81)

        // 目标不可读时绝不回退到100%。
        input.currentLevel = 50
        input.chargeTargetPercent = nil
        #expect(RuntimeEstimator.chargeEstimate(input) == nil)
    }

    /// 放电斜率异常上限（与充电/功率路径同规则）：密集采样的 SMC 重校准跳变
    /// 序列（每分钟 -4%，240%/h）→ 直接拒绝，不得输出「剩余 12 分钟」。
    @Test func absurdDischargeSlopeIsRejected() {
        var input = RuntimeEstimator.Inputs()
        input.now = t0.addingTimeInterval(1200)
        input.currentLevel = 10
        input.externalConnected = false
        // 20 分钟从 90% 掉到 10%：跨度/净降/覆盖率全部达标，唯独斜率 240%/h
        input.snapshots = (0...20).map { minute in
            snapshot(TimeInterval(minute * 60), 90 - Double(minute) * 4.0)
        }
        #expect(RuntimeEstimator.historicalSlopeEvidence(input) == nil)
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)

        // 合法高负载放电（25%/h）不受影响
        input.snapshots = (0...20).map { minute in
            snapshot(TimeInterval(minute * 60), 80 - Double(minute) * (25.0 / 60.0))
        }
        input.currentLevel = 71.6
        let fast = RuntimeEstimator.historicalSlopeEvidence(input)
        #expect(fast != nil)
    }

    // MARK: 充电功率证据（CC+CV 上限感知）与系统充电估算

    private func chargeAggregates(watts: Double, minutes: Int, endingAt end: Date) -> [MinuteAggregate] {
        let start = end.addingTimeInterval(-TimeInterval(minutes * 60))
        return (0..<minutes).map { minute in
            MinuteAggregate(
                windowStart: start.addingTimeInterval(TimeInterval(minute * 60)),
                systemEnergyWh: 12 * 60 / 3600,
                systemPowerAverage: 12,
                systemPowerPeak: 12,
                systemCoverage: 1,
                batteryChargeSeconds: 60,
                batteryDischargeWh: 0,
                batteryDischargeSeconds: 0,
                temperatureAverage: 32,
                temperatureMaximum: 33,
                temperatureCoverage: 1,
                batteryChargeWh: watts * 60 / 3600
            )
        }
    }

    @Test func windowAggregatorAccumulatesBatteryChargeWh() throws {
        var aggregator = WindowTelemetryAggregator()
        for step in 0...12 {
            aggregator.observe(WindowTelemetryAggregator.Observation(
                date: t0.addingTimeInterval(TimeInterval(step * 5)),
                trustedSystemLoad: 15,
                batteryChannel: .charge(30),
                temperatureCelsius: 33,
                expectedInterval: 5
            ))
        }
        let completed = aggregator.takeCompletedAggregate()
        let minute = try #require(completed)
        #expect(abs(minute.batteryChargeSeconds - 60) < 1e-9)
        #expect(abs(minute.batteryChargeWh - 0.5) < 1e-6)
        #expect(minute.batteryDischargeSeconds == 0)
    }

    @Test func chargePowerEvidenceMonotonicAcrossAllLimitsAndAppliesCVTaper() throws {
        // 5000 mAh × 12 V = 60 Wh，30 W 实时充电功率 → CC 线性速率 50%/h（1.2 分钟/%）
        var base = RuntimeEstimator.Inputs()
        base.now = t0.addingTimeInterval(600)
        base.currentLevel = 50
        base.externalConnected = true
        base.isCharging = true
        base.fullChargeCapacityMah = 5000
        base.voltageMV = 12_000
        base.liveChargeWatts = 30

        var hoursByGoal: [Int: Double] = [:]
        for goal in [80, 85, 90, 95, 100] {
            var input = base
            input.chargeTargetPercent = Double(goal)
            let evidence = try #require(RuntimeEstimator.chargePowerEvidence(input))
            #expect(evidence.basis == .batteryPower)
            #expect(evidence.goalPercent == Double(goal))
            #expect(evidence.confidence == 0.50)
            hoursByGoal[goal] = evidence.valueHours

            // 无历史快照时 chargeEstimate 自动回退到 chargePowerEvidence
            let fallback = try #require(RuntimeEstimator.chargeEstimate(input))
            #expect(fallback == evidence)
        }

        // 严格单调递增：80% < 85% < 90% < 95% < 100%
        let h80 = try #require(hoursByGoal[80])
        let h85 = try #require(hoursByGoal[85])
        let h90 = try #require(hoursByGoal[90])
        let h95 = try #require(hoursByGoal[95])
        let h100 = try #require(hoursByGoal[100])
        #expect(h80 < h85 && h85 < h90 && h90 < h95 && h95 < h100)

        // 50→80% 纯 CC 线性：60 Wh × 30% / 30 W = 0.60 h
        #expect(abs(h80 - 0.60) < 1e-6)
        // 80→100% CV 降功率段每 1% 耗时显著慢于 50→80% 线性段
        let hoursPerPercentCC = h80 / 30.0
        let hoursPerPercentCV = (h100 - h80) / 20.0
        #expect(hoursPerPercentCV > hoursPerPercentCC * 1.4)

        // 聚合分钟窗口（≥120s）优先于 liveChargeWatts 并提升置信度
        var aggregatedInput = base
        aggregatedInput.chargeTargetPercent = 95
        aggregatedInput.minuteAggregates = chargeAggregates(watts: 24, minutes: 5, endingAt: aggregatedInput.now)
        let aggResult = try #require(RuntimeEstimator.chargePowerEvidence(aggregatedInput))
        #expect(aggResult.evidenceDuration == 300)
        #expect(aggResult.coverage == 0.5)
        #expect(aggResult.confidence > 0.50 && aggResult.confidence <= 0.66)
        #expect(aggResult.valueHours > h95) // 24W 慢于 30W
    }

    @Test func chargePowerEvidenceWorksAboveEightyPercentAndRejectsInvalidInputs() throws {
        // 85% 起点仍可估算到 95% 与 100%，且保守折减后仍满足展示门槛
        var base = RuntimeEstimator.Inputs()
        base.now = t0.addingTimeInterval(600)
        base.currentLevel = 85
        base.externalConnected = true
        base.isCharging = true
        base.fullChargeCapacityMah = 5000
        base.voltageMV = 12_000
        base.liveChargeWatts = 20

        var to95 = base
        to95.chargeTargetPercent = 95
        let est95 = try #require(RuntimeEstimator.chargeEstimate(to95))
        #expect(est95.basis == .batteryPower)
        #expect(est95.goalPercent == 95)
        #expect(est95.failureReason == "涓流充电阶段")

        var to100 = base
        to100.chargeTargetPercent = 100
        let est100 = try #require(RuntimeEstimator.chargeEstimate(to100))
        #expect(est100.valueHours > est95.valueHours)

        // 估算满充容量叠加 >80% 仍保底满足展示门槛（0.50 × 0.90 × 0.92 = 0.414 ≥ 0.40）
        var estimatedCap = to100
        estimatedCap.fullChargeCapacityIsEstimated = true
        let estCapResult = try #require(RuntimeEstimator.chargePowerEvidence(estimatedCap))
        #expect(estCapResult.confidence < est100.confidence)

        // 无效电压 / 无效功率 / 暂停 / 已达目标 / 目标未知一律拒绝
        var badVoltage = to100; badVoltage.voltageMV = 0
        #expect(RuntimeEstimator.chargePowerEvidence(badVoltage) == nil)
        var lowPower = to100; lowPower.liveChargeWatts = 0.8
        #expect(RuntimeEstimator.chargePowerEvidence(lowPower) == nil)
        var absurdPower = to100; absurdPower.liveChargeWatts = 300
        #expect(RuntimeEstimator.chargePowerEvidence(absurdPower) == nil)
        var paused = to100; paused.isCharging = false
        #expect(RuntimeEstimator.chargePowerEvidence(paused) == nil)
        var atLimit = base; atLimit.chargeTargetPercent = 85
        #expect(RuntimeEstimator.chargePowerEvidence(atLimit) == nil)
        var noGoal = base; noGoal.chargeTargetPercent = nil
        #expect(RuntimeEstimator.chargePowerEvidence(noGoal) == nil)
    }

    @Test func systemReportedChargeEstimateOnlyActivatesForFullChargeTarget() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = t0
        input.currentLevel = 60
        input.externalConnected = true
        input.isCharging = true
        input.systemReportedMinutes = 45
        input.chargeTargetPercent = 100

        let full = try #require(RuntimeEstimator.systemReportedChargeEstimate(input))
        #expect(full.basis == .systemReported)
        #expect(full.goalPercent == 100)
        #expect(abs(full.valueHours - 0.75) < 1e-9)
        #expect(full.confidence == 0.3)

        // 自定义 80/85/90/95% 上限或未知目标绝不借用系统的 100% 充满时间
        for customGoal in [80.0, 85.0, 90.0, 95.0] {
            var custom = input
            custom.chargeTargetPercent = customGoal
            #expect(RuntimeEstimator.systemReportedChargeEstimate(custom) == nil)
        }
        var nilGoal = input; nilGoal.chargeTargetPercent = nil
        #expect(RuntimeEstimator.systemReportedChargeEstimate(nilGoal) == nil)

        // 暂停或无效分钟数返回 nil
        var paused = input; paused.isCharging = false
        #expect(RuntimeEstimator.systemReportedChargeEstimate(paused) == nil)
        var unavailable = input; unavailable.systemReportedMinutes = -1
        #expect(RuntimeEstimator.systemReportedChargeEstimate(unavailable) == nil)
    }
}
