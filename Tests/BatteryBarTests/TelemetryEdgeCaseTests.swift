import Foundation
import Testing
@testable import BatteryBar

private final class MutableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { self.current = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }
}

private final class StubPolicyRunner: ChargePolicyCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var target = 80

    func setTarget(_ value: Int) {
        lock.lock()
        target = value
        lock.unlock()
    }

    func read() -> ChargePolicyCommandResult {
        lock.lock()
        let current = target
        lock.unlock()
        return ChargePolicyCommandResult(
            stdout: """
            Battery level limits:
            (
                { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = \(current); }
            )
            """,
            exitCode: 0
        )
    }
}

@Suite struct TelemetryEdgeCaseTests {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    // MARK: - 1. 负温度解析与来源

    @Test func negativeTemperaturesArePreservedWithCorrectSource() {
        let smart = BatteryReader.resolveTemperature(
            smartBatteryCandidates: [-500],
            packCandidates: [2500]
        )
        #expect(smart.value == -5.0)
        #expect(smart.source == .smartBatteryTemperature)

        let pack = BatteryReader.resolveTemperature(
            smartBatteryCandidates: [0, nil],
            packCandidates: [-1250]
        )
        #expect(pack.value == -12.5)
        #expect(pack.source == .smartBatteryPackTemperature)

        let invalid = BatteryReader.resolveTemperature(
            smartBatteryCandidates: [0, -2500, 15000],
            packCandidates: [nil, 0.1]
        )
        #expect(invalid.value == 0)
        #expect(invalid.source == nil)
    }

    // MARK: - 2. 充电策略 TTL 刷新与延迟绑定

    @Test @MainActor func policyRefreshWithUnchangedTargetPreservesRevisionAcrossTTL() async {
        let clock = MutableClock(base)
        let runner = StubPolicyRunner()
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { monitor.snapshot.targetPercent == 80 }
        let initialRevision = monitor.revision
        #expect(initialRevision > 0)

        // 超过 TTL 后先进入 stale（targetPercent == nil），再刷新读回同一 80% 目标
        clock.set(base.addingTimeInterval(ChargePolicyMonitor.cacheTTL + 5))
        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil {
            monitor.snapshot.status == .configured && monitor.snapshot.readAt == clock.now()
        }
        #expect(monitor.snapshot.targetPercent == 80)
        #expect(monitor.revision == initialRevision)

        // 目标真正变化到 85% 时 revision 必须递增
        runner.setTarget(85)
        clock.set(clock.now().addingTimeInterval(ChargePolicyMonitor.minimumForcedRefreshInterval + 5))
        monitor.refreshIfNeeded(force: true, now: clock.now())
        await waitUntil { monitor.snapshot.targetPercent == 85 }
        #expect(monitor.revision == initialRevision + 1)
    }

    @Test func chargeCompletionTrackerLateBindsTargetForObservedStartOnly() throws {
        // 场景 A：接电起充时策略尚未返回（nil），充电中途策略就绪（80%），达标停充应产出完成证据
        var tracker = ChargeCompletionTracker()
        #expect(tracker.observe(pluggedIn: false, isCharging: false, level: 70, targetPercent: nil, policyRevision: 0) == nil)
        #expect(tracker.observe(pluggedIn: true, isCharging: true, level: 70, targetPercent: nil, policyRevision: 0) == nil)
        #expect(tracker.observe(pluggedIn: true, isCharging: true, level: 73, targetPercent: 80, policyRevision: 1) == nil)
        let observedCompleted = tracker.observe(
            pluggedIn: true, isCharging: false, level: 80, targetPercent: 80, policyRevision: 1
        )
        let completed = try #require(observedCompleted)
        #expect(completed.targetPercent == 80)
        #expect(completed.policyRevision == 1)
        #expect(completed.startLevel == 73)

        // 场景 B：启动时已经在充电（未观察到起充边界）绝不延迟补建候选，防止误报
        var launchedCharging = ChargeCompletionTracker()
        #expect(launchedCharging.observe(pluggedIn: true, isCharging: true, level: 70, targetPercent: nil, policyRevision: 0) == nil)
        #expect(launchedCharging.observe(pluggedIn: true, isCharging: true, level: 75, targetPercent: 80, policyRevision: 1) == nil)
        #expect(launchedCharging.observe(pluggedIn: true, isCharging: false, level: 80, targetPercent: 80, policyRevision: 1) == nil)
    }

    // MARK: - 3. 午夜夏令时（America/Havana 2026-03-08 00:00 → 01:00）全链路边界

    @Test func midnightDSTSpringForwardHandledAcrossCalendarHistoryAndAggregator() throws {
        var cal = Calendar(identifier: .gregorian)
        let havana = try #require(TimeZone(identifier: "America/Havana"))
        cal.timeZone = havana

        let march8Noon = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 8, hour: 12)))
        let march9Start = cal.startOfDay(for: try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 9, hour: 12))))
        let march10Noon = try #require(cal.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12)))
        let march8Start = cal.startOfDay(for: march8Noon)

        let dayBounds = HistoryCalendar.bounds(
            period: .day, selection: march8Noon, first: march8Start, now: march10Noon, calendar: cal
        )
        #expect(dayBounds.start == march8Start)
        #expect(dayBounds.end == march9Start)
        #expect(dayBounds.duration == 23 * 3_600)

        let window = UsageDateWindow(
            firstRecordedAt: march8Start, selectedDate: march9Start, now: march10Noon, calendar: cal
        )
        #expect(window.days.contains(march8Start))
        #expect(window.days.contains(march9Start))
        #expect(window.days.allSatisfy { cal.startOfDay(for: $0) == $0 })

        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        let beforeMidnight = march9Start.addingTimeInterval(-60)
        aggregator.observe(.init(
            date: beforeMidnight, externalConnected: true, screenOn: true,
            level: 80, timeZone: havana
        ))
        aggregator.observe(.init(
            date: march9Start.addingTimeInterval(60), externalConnected: true, screenOn: true,
            level: 80, timeZone: havana
        ))
        aggregator.stop(at: march9Start.addingTimeInterval(75))
        let buckets = aggregator.takeCompleted()
        let march8Buckets = buckets.filter { cal.startOfDay(for: $0.start) == march8Start }
        #expect(!march8Buckets.isEmpty)
        #expect(march8Buckets.allSatisfy { $0.end <= march9Start })

        var summary = UsageDailySummary(bucket: march8Buckets[0])
        for bucket in march8Buckets { summary.include(bucket) }
        #expect(summary.isValid)
        #expect(summary.appliedThrough == march9Start)

        let reviews = UsageHistoryAnalysis.reviews(
            stored: buckets, live: [], dates: [march8Noon], calendar: cal, now: march10Noon
        )
        #expect(reviews[0].elapsedSeconds == 23 * 3_600)
        #expect(reviews[0].end == march9Start)
    }

    // MARK: - 4. HistoryCalendar / ProductPresentation 防御边界

    @Test func historyCalendarAndPresentationsHandleEdgeInputsSafely() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let futureFirst = base.addingTimeInterval(86_400 * 3)
        let all = HistoryCalendar.bounds(
            period: .all, selection: base, first: futureFirst, now: base, calendar: cal
        )
        #expect(all.start <= all.end)

        #expect(BatteryLevelPresentation.percent(.nan) == 0)
        #expect(BatteryLevelPresentation.percent(.infinity) == 0)
        #expect(BatteryLevelPresentation.percent(-5) == 0)
        #expect(BatteryLevelPresentation.percent(105) == 100)

        let paused = ChargingBehaviorObservation(
            state: .otherConfirmedPause, reason: .unknown,
            source: "IOPS", observedAt: base
        )
        let state = PowerStatePresentation.resolve(
            external: true, charging: false, level: 80, target: 50, behavior: paused
        )
        #expect(state.detail == paused.displayLabel)

        let badTarget = PowerStatePresentation.resolve(
            external: true, charging: true, level: 50, target: 50, behavior: nil
        )
        #expect(badTarget.detail == "正在向电池充电")
    }

    // MARK: - 5. UsageTelemetryAggregator 唤醒回拨与 unknown 连续性断开

    @Test func aggregatorRecoversFromClockRollbackOnWakeAndBreaksUnknownContinuity() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        let utc = TimeZone(secondsFromGMT: 0)!
        aggregator.observe(.init(date: base, externalConnected: false, screenOn: true, level: 80, dischargePower: 6, timeZone: utc))
        aggregator.sleep(at: base.addingTimeInterval(60))
        // 时钟回拨导致 wake 早于 sleep：不得永久卡死在睡眠态，且记录一次时钟回拨
        aggregator.wake(at: base.addingTimeInterval(30))
        aggregator.observe(.init(date: base.addingTimeInterval(75), externalConnected: false, screenOn: true, level: 79, dischargePower: 6, timeZone: utc))
        aggregator.observe(.init(date: base.addingTimeInterval(90), externalConnected: nil, screenOn: true, level: 79, timeZone: utc))
        aggregator.observe(.init(date: base.addingTimeInterval(105), externalConnected: false, screenOn: true, level: 78, dischargePower: 6, timeZone: utc))
        aggregator.stop(at: base.addingTimeInterval(120))

        let buckets = aggregator.takeCompleted()
        #expect(buckets.reduce(0) { $0 + $1.sleepSeconds } == 0)
        #expect(buckets.reduce(0) { $0 + ($1.clockRollbackCount ?? 0) } == 1)
        #expect(buckets.reduce(0) { $0 + $1.screenOnSeconds } == 60)
        let levels = buckets.flatMap(\.levels)
        #expect(!levels.contains { $0.date == base.addingTimeInterval(90) })
        let beforeUnknown = levels.last { $0.date < base.addingTimeInterval(90) }
        let afterUnknown = levels.first { $0.date > base.addingTimeInterval(90) }
        #expect(beforeUnknown != nil && afterUnknown != nil)
        #expect(beforeUnknown?.continuityID != afterUnknown?.continuityID)
    }

    // MARK: - 6. RuntimeEstimator 融合区间、重复分钟去重、覆盖率夹紧与非有限保护

    @Test func runtimeEstimatorGuardsFusedBoundsDuplicatesCoverageAndNonFinite() throws {
        let twoEndpoints = [(base, 80.0), (base.addingTimeInterval(1200), 75.0)]
        let coverage = RuntimeEstimator.coveredFraction(points: twoEndpoints, span: 1200)
        #expect(abs(coverage - 65.0 / 1200.0) < 1e-6)

        let duplicateWindows = (0..<6).flatMap { minute -> [MinuteAggregate] in
            let agg = MinuteAggregate(
                windowStart: base.addingTimeInterval(TimeInterval(minute * 60)),
                systemEnergyWh: 0.1, systemPowerAverage: 6, systemPowerPeak: 6, systemCoverage: 1,
                batteryChargeSeconds: 0,
                batteryDischargeWh: 0.1, batteryDischargeSeconds: 60,
                temperatureAverage: 30, temperatureMaximum: 30, temperatureCoverage: 1
            )
            return [agg, agg]
        }
        var dupInput = RuntimeEstimator.Inputs()
        dupInput.now = base.addingTimeInterval(360)
        dupInput.currentLevel = 60
        dupInput.externalConnected = false
        dupInput.minuteAggregates = duplicateWindows
        dupInput.fullChargeCapacityMah = 5000
        dupInput.voltageMV = 12_000
        #expect(RuntimeEstimator.batteryPowerEvidence(dupInput) == nil)

        var fusedInput = RuntimeEstimator.Inputs()
        fusedInput.now = base.addingTimeInterval(3600)
        fusedInput.currentLevel = 75
        fusedInput.externalConnected = false
        fusedInput.snapshots = (0...60).map { minute in
            BatterySnapshot(
                timestamp: base.addingTimeInterval(TimeInterval(minute * 60)),
                level: 80 - Double(minute) * (5.0 / 60.0),
                isCharging: false, wattage: 8,
                externalConnected: false
            )
        }
        fusedInput.minuteAggregates = (0..<15).map { minute in
            MinuteAggregate(
                windowStart: base.addingTimeInterval(TimeInterval(2700 + minute * 60)),
                systemEnergyWh: 0.5, systemPowerAverage: 30, systemPowerPeak: 30, systemCoverage: 1,
                batteryChargeSeconds: 0,
                batteryDischargeWh: 0.5, batteryDischargeSeconds: 60,
                temperatureAverage: 30, temperatureMaximum: 30, temperatureCoverage: 1
            )
        }
        fusedInput.fullChargeCapacityMah = 5000
        fusedInput.voltageMV = 12_000
        let fused = try #require(RuntimeEstimator.dischargeEstimate(fusedInput))
        let lower = try #require(fused.lowerHours)
        let upper = try #require(fused.upperHours)
        #expect(lower <= fused.valueHours && fused.valueHours <= upper)
        #expect(upper < 25)

        var nanInput = fusedInput
        nanInput.currentLevel = .nan
        nanInput.systemReportedMinutes = 120
        #expect(RuntimeEstimator.dischargeEstimate(nanInput) == nil)
        #expect(RuntimeEstimator.systemReportedEstimate(nanInput) == nil)
        #expect(RuntimeEstimator.median(of: [.nan, 4, 8]) == 6)
    }

    // MARK: - 7. ChartDownsampler

    @Test func chartDownsamplerHonorsStrictMaxPointsAndBoundaries() {
        let trend = (0..<241).map { i in
            TrendPoint(time: base.addingTimeInterval(Double(i * 60)), value: Double(i), breakBefore: i == 120)
        }
        let sampled = ChartDownsampler.downsampleTrendPoints(trend, maxPoints: 240)
        #expect(sampled.count <= 240)
        #expect(sampled.first?.time == trend.first?.time)
        #expect(sampled.last?.time == trend.last?.time)
        #expect(sampled.contains { $0.breakBefore })
        #expect(ChartDownsampler.downsampleTrendPoints(trend, maxPoints: 0).isEmpty)
        #expect(ChartDownsampler.downsampleTrendPoints(trend, maxPoints: 1).count == 1)

        let snaps = (0..<10).map { i in
            BatterySnapshot(
                timestamp: base.addingTimeInterval(Double(i * 60)),
                level: 80, isCharging: false, wattage: i == 5 ? 42 : 8
            )
        }
        let three = ChartDownsampler.powerSnapshots(snaps, maxPoints: 3)
        #expect(three.count == 3)
        #expect(three[1].wattage == 42)
    }

    // MARK: - 8. RangeStatistics / UsageHistoryAnalysis / UsageBucket

    @Test func rangeStatisticsPrefersHigherCoverageDuplicateAndBucketRejectsOverlap() {
        var low = BatterySnapshot(timestamp: base, level: 80, isCharging: false, wattage: 10)
        low.aggregateWindowStart = base
        low.systemCoverage = 0.2
        low.systemEnergyWh = 0.05

        var high = BatterySnapshot(timestamp: base.addingTimeInterval(5), level: 80, isCharging: false, wattage: 10)
        high.aggregateWindowStart = base
        high.systemCoverage = 1.0
        high.systemEnergyWh = 0.25

        let end = base.addingTimeInterval(60)
        #expect(RangeStatistics.overallSystemCoverage(snapshots: [low, high], rangeStart: base, rangeEnd: end) == 1.0)
        #expect(RangeStatistics.trustedSystemEnergyWh(snapshots: [low, high], rangeStart: base, rangeEnd: end) == 0.25)

        let epoch = UUID()
        let run = UUID()
        let cont = UUID()
        let session = UUID()
        let utc = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc
        let b1 = UsageBucket(
            measurementEpoch: epoch, runID: run, timeZoneID: utc.identifier,
            start: base, end: base.addingTimeInterval(300),
            screenOnSeconds: 300, dischargeWh: 0.5, powerSeconds: 300,
            spans: [UsageSpan(start: base, end: base.addingTimeInterval(300), activity: .batteryScreenOn,
                              sessionID: session, continuityID: cont, dischargeWh: 0.5, powerSeconds: 300)]
        )
        let b2 = UsageBucket(
            measurementEpoch: epoch, runID: run, timeZoneID: utc.identifier,
            start: base.addingTimeInterval(300), end: base.addingTimeInterval(600),
            screenOnSeconds: 300, dischargeWh: 0.7, powerSeconds: 300,
            spans: [UsageSpan(start: base.addingTimeInterval(300), end: base.addingTimeInterval(600), activity: .batteryScreenOn,
                              sessionID: session, continuityID: cont, dischargeWh: 0.7, powerSeconds: 300)]
        )
        let review = UsageHistoryAnalysis.reviews(
            stored: [b1, b2], live: [], dates: [base], calendar: cal, now: base.addingTimeInterval(700)
        )[0]
        #expect(review.spans.count == 1)
        #expect(abs(review.spans[0].dischargeWh - 1.2) < 1e-9)
        #expect(review.spans[0].powerSeconds == 600)

        let overlapping = UsageBucket(
            measurementEpoch: epoch, runID: run, timeZoneID: utc.identifier,
            start: base, end: base.addingTimeInterval(120),
            onPowerSeconds: 120,
            spans: [
                UsageSpan(start: base, end: base.addingTimeInterval(90), activity: .onPower, continuityID: cont),
                UsageSpan(start: base.addingTimeInterval(60), end: base.addingTimeInterval(120), activity: .onPower, continuityID: cont),
            ]
        )
        #expect(!overlapping.isValid)
    }

    // MARK: - 9. PowerSelection / Health / NotificationPolicy / Retention 防御

    @Test func powerSelectionHealthParserAndNotificationCooldownGuards() {
        #expect(BatteryPowerSelection.resolve(directCandidates: [], voltage: 20_000, amperage: 30_000) == .unavailable)
        #expect(BatteryPowerSelection.resolve(directCandidates: [], voltage: .nan, amperage: 1_000) == .unavailable)

        let health = BatteryHealthMetric.systemProfilerHealthPercent(json: [
            "SPPowerDataType": [
                ["sppower_battery_health_info": ["sppower_battery_health_maximum_capacity": " 97% \n"]]
            ]
        ])
        #expect(health == 97)

        let futureSnap = BatterySnapshot(
            timestamp: base.addingTimeInterval(3_600),
            level: 80, isCharging: false, wattage: 8
        )
        #expect(DataStore.retainedSnapshots([futureSnap], now: base).isEmpty)

        #expect(NotificationPolicy.cooldownElapsed(
            last: base.addingTimeInterval(600),
            cooldown: NotificationPolicy.lowBatteryCooldown,
            now: base
        ))
    }

    // MARK: - 10. 边界回归测试（融合置信度、分钟队列、边界电量、低温换算、损坏 Epoch 修复）

    @Test func agreeingFusedEvidenceNeverLowersConfidenceAndSystemEstimateRejectsSentinels() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = base.addingTimeInterval(1200)
        input.currentLevel = 60
        input.externalConnected = false
        input.snapshots = (0...20).map { minute in
            BatterySnapshot(
                timestamp: base.addingTimeInterval(TimeInterval(minute * 60)),
                level: 62 - Double(minute) * 0.1,
                isCharging: false, wattage: 6,
                externalConnected: false
            )
        }
        input.minuteAggregates = (0..<15).map { minute in
            MinuteAggregate(
                windowStart: base.addingTimeInterval(TimeInterval(300 + minute * 60)),
                systemEnergyWh: 0.1, systemPowerAverage: 6, systemPowerPeak: 6, systemCoverage: 1,
                batteryChargeSeconds: 0,
                batteryDischargeWh: 0.1, batteryDischargeSeconds: 60,
                temperatureAverage: 30, temperatureMaximum: 30, temperatureCoverage: 1
            )
        }
        input.fullChargeCapacityMah = 5000
        input.voltageMV = 12_000

        let power = try #require(RuntimeEstimator.batteryPowerEvidence(input))
        let fused = try #require(RuntimeEstimator.dischargeEstimate(input))
        #expect(fused.basis == .fused)
        #expect(fused.confidence >= power.confidence)

        var sysInput = RuntimeEstimator.Inputs()
        sysInput.externalConnected = false
        sysInput.isCharging = false
        sysInput.currentLevel = 50
        sysInput.systemReportedMinutes = 65_535
        #expect(RuntimeEstimator.systemReportedEstimate(sysInput) == nil)
        sysInput.systemReportedMinutes = 120
        sysInput.currentLevel = 0
        #expect(RuntimeEstimator.systemReportedEstimate(sysInput) == nil)
    }

    @Test func windowTelemetryAggregatorQueuesMultipleCompletedMinutes() {
        var agg = WindowTelemetryAggregator()
        for step in 0...25 {
            let t = base.addingTimeInterval(TimeInterval(step * 5))
            agg.observe(.init(
                date: t,
                trustedSystemLoad: 10,
                batteryChannel: .discharge(10),
                temperatureCelsius: 32,
                expectedInterval: 5
            ))
        }
        let completed = agg.takeCompletedAggregates()
        #expect(completed.count == 2)
        #expect(completed[0].windowStart == base)
        #expect(completed[1].windowStart == base.addingTimeInterval(60))
        #expect(agg.takeCompletedAggregates().isEmpty)
    }

    @Test func usageAggregatorPreservesExactBoundaryLevelAndFiltersUnknownPreview() {
        var agg = UsageTelemetryAggregator(measurementEpoch: UUID())
        let utc = TimeZone(secondsFromGMT: 0)!
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        agg.observe(.init(date: start, externalConnected: nil, screenOn: true, level: 80, timeZone: utc))
        agg.observe(.init(date: start.addingTimeInterval(15), externalConnected: nil, screenOn: true, level: 80, timeZone: utc))
        #expect(agg.preview(at: start.addingTimeInterval(20)).isEmpty)

        var agg2 = UsageTelemetryAggregator(measurementEpoch: UUID())
        agg2.observe(.init(date: start.addingTimeInterval(270), externalConnected: false, screenOn: true, level: 80, dischargePower: 8, timeZone: utc))
        agg2.observe(.init(date: start.addingTimeInterval(285), externalConnected: false, screenOn: true, level: 80, dischargePower: 8, timeZone: utc))
        agg2.observe(.init(date: start.addingTimeInterval(300), externalConnected: true, screenOn: true, level: 79, timeZone: utc))
        let completed = agg2.takeCompleted()
        #expect(completed.count == 1)
        #expect(completed[0].levels.last?.level == 79)
        #expect(completed[0].levels.last?.date == start.addingTimeInterval(300))
    }

    @Test func temperatureNormalizationHandlesCentiDegreesAndCorruptEpochIsRepaired() throws {
        #expect(abs(BatteryReader.normalizedBatteryTemperature(125) - 1.25) < 0.0001)
        #expect(abs(BatteryReader.normalizedBatteryTemperature(-125) - (-1.25)) < 0.0001)
        #expect(BatteryReader.normalizedBatteryTemperature(31.5) == 31.5)

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-corrupt-epoch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let metaURL = dir.appendingPathComponent("usage-history-epoch.json")
        try Data("corrupt-json".utf8).write(to: metaURL)

        let store1 = UsageHistoryStore(directory: dir, now: base)
        let firstEpoch = store1.measurementEpoch
        var bucket = UsageBucket(
            measurementEpoch: firstEpoch, runID: UUID(), timeZoneID: "UTC",
            start: base, end: base.addingTimeInterval(60)
        )
        bucket.onPowerSeconds = 60
        store1.append([bucket], now: base.addingTimeInterval(60))

        let store2 = UsageHistoryStore(directory: dir, now: base.addingTimeInterval(120))
        #expect(store2.measurementEpoch == firstEpoch)
    }

    // MARK: - 11. 设计补全回归：离电时段起止边界完整性 & 采样缺口原因明细

    @Test func sessionBoundariesDistinguishObservedAndIncompleteEdges() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc

        // 场景 A：完整观测到「接电 → 离电（亮屏 + 息屏）→ 接电」
        var completeAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        completeAgg.observe(.init(date: base, externalConnected: true, screenOn: true, level: 90, timeZone: utc))
        completeAgg.observe(.init(date: base.addingTimeInterval(15), externalConnected: false, screenOn: true, level: 90, dischargePower: 6, timeZone: utc))
        completeAgg.observe(.init(date: base.addingTimeInterval(30), externalConnected: false, screenOn: false, level: 89, dischargePower: 4, timeZone: utc))
        completeAgg.observe(.init(date: base.addingTimeInterval(45), externalConnected: true, screenOn: true, level: 89, timeZone: utc))
        completeAgg.stop(at: base.addingTimeInterval(60))

        let completeReview = UsageHistoryAnalysis.reviews(
            stored: completeAgg.takeCompleted(), live: [], dates: [base], calendar: cal, now: base.addingTimeInterval(120)
        )[0]
        let completeSession = try #require(completeReview.sessions.first)
        #expect(!completeSession.ongoing)
        #expect(!completeSession.startIncomplete)
        #expect(!completeSession.endIncomplete)

        // 场景 B：启动即离电 + 休眠截断 → 起止边界均未完整记录
        var truncatedAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        truncatedAgg.observe(.init(date: base, externalConnected: false, screenOn: true, level: 80, dischargePower: 6, timeZone: utc))
        truncatedAgg.sleep(at: base.addingTimeInterval(30))
        truncatedAgg.wake(at: base.addingTimeInterval(90))
        truncatedAgg.stop(at: base.addingTimeInterval(90))

        let truncatedReview = UsageHistoryAnalysis.reviews(
            stored: truncatedAgg.takeCompleted(), live: [], dates: [base], calendar: cal, now: base.addingTimeInterval(120)
        )[0]
        let truncatedSession = try #require(truncatedReview.sessions.first)
        #expect(!truncatedSession.ongoing)
        #expect(truncatedSession.startIncomplete)
        #expect(truncatedSession.endIncomplete)

        // 场景 C：观测到拔电但尚未插电（进行中）→ startIncomplete=false, ongoing=true, endIncomplete=false
        var liveAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        liveAgg.observe(.init(date: base, externalConnected: true, screenOn: true, level: 85, timeZone: utc))
        liveAgg.observe(.init(date: base.addingTimeInterval(15), externalConnected: false, screenOn: true, level: 85, dischargePower: 6, timeZone: utc))
        let liveReview = UsageHistoryAnalysis.reviews(
            stored: liveAgg.takeCompleted(),
            live: liveAgg.preview(at: base.addingTimeInterval(30)),
            dates: [base], calendar: cal, now: base.addingTimeInterval(30)
        )[0]
        let liveSession = try #require(liveReview.sessions.first)
        #expect(liveSession.ongoing)
        #expect(!liveSession.startIncomplete)
        #expect(!liveSession.endIncomplete)

        // 场景 D：历史旧桶（startObserved/endObserved == nil）不误标为不完整
        let legacyBucket = UsageBucket(
            measurementEpoch: UUID(), runID: UUID(), timeZoneID: utc.identifier,
            start: base, end: base.addingTimeInterval(60),
            screenOnSeconds: 60, dischargeWh: 0.1, powerSeconds: 60,
            spans: [UsageSpan(start: base, end: base.addingTimeInterval(60), activity: .batteryScreenOn,
                              sessionID: UUID(), continuityID: UUID(), dischargeWh: 0.1, powerSeconds: 60)]
        )
        let legacyReview = UsageHistoryAnalysis.reviews(
            stored: [legacyBucket], live: [], dates: [base], calendar: cal, now: base.addingTimeInterval(120)
        )[0]
        let legacySession = try #require(legacyReview.sessions.first)
        #expect(!legacySession.startIncomplete)
        #expect(!legacySession.endIncomplete)
    }

    @Test func gapReasonsAndSkippedLinesSurfaceInUsageDayReview() {
        let utc = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc

        // 1) 采样超时缺口：t=0 观测（hold 30s）→ t=150 再次观测 → 120s 记入 samplingGapSeconds
        var gapAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        gapAgg.observe(.init(date: base, externalConnected: false, screenOn: true, level: 80, dischargePower: 6, expectedInterval: 15, timeZone: utc))
        gapAgg.observe(.init(date: base.addingTimeInterval(150), externalConnected: false, screenOn: true, level: 79, dischargePower: 6, expectedInterval: 15, timeZone: utc))
        gapAgg.stop(at: base.addingTimeInterval(165))
        let gapBuckets = gapAgg.takeCompleted()
        #expect(gapBuckets.allSatisfy { $0.isValid })
        #expect(gapBuckets.reduce(0) { $0 + ($1.samplingGapSeconds ?? 0) } == 120)

        // 2) 读取失败缺口：t=300 观测 → t=305 invalidate → t=360 恢复 → 55s 记入 readFailureSeconds
        var failAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        failAgg.observe(.init(date: base.addingTimeInterval(300), externalConnected: false, screenOn: true, level: 79, dischargePower: 6, expectedInterval: 5, timeZone: utc))
        failAgg.invalidate(at: base.addingTimeInterval(305))
        failAgg.observe(.init(date: base.addingTimeInterval(360), externalConnected: false, screenOn: true, level: 78, dischargePower: 6, expectedInterval: 5, timeZone: utc))
        failAgg.stop(at: base.addingTimeInterval(365))
        let failBuckets = failAgg.takeCompleted()
        #expect(failBuckets.allSatisfy { $0.isValid })
        #expect(failBuckets.reduce(0) { $0 + ($1.readFailureSeconds ?? 0) } == 55)

        // 3) 汇总到 UsageDayReview 并透传 skippedLines
        let queryNow = base.addingTimeInterval(600)
        let review = UsageReportQuery.day(
            base,
            summaries: [],
            buckets: gapBuckets + failBuckets,
            live: [],
            calendar: cal,
            now: queryNow,
            skippedLines: 3
        )
        #expect(review.samplingGapSeconds == 120)
        #expect(review.readFailureSeconds == 55)
        #expect(review.skippedLines == 3)
        #expect(abs(review.unrecordedSeconds - max(0, review.unknownSeconds - 120 - 55)) < 1e-9)
    }

    // MARK: - 12. 可靠性加固回归（时钟回拨、健康来源、读取缺口、日汇总恢复）

    @Test func monotonicClockResumesAggregatorsAfterOneHourWallClockRollback() throws {
        // 1) WindowTelemetryAggregator：单调时钟递增但墙钟回拨 1 小时后，必须立刻恢复分钟聚合，不卡死且不倒向积分
        var winAgg = WindowTelemetryAggregator()
        winAgg.observe(.init(date: base, trustedSystemLoad: 10, batteryChannel: .discharge(10),
                             temperatureCelsius: 30, expectedInterval: 15, monotonicTime: 1_000))
        winAgg.observe(.init(date: base.addingTimeInterval(20), trustedSystemLoad: 10, batteryChannel: .discharge(10),
                             temperatureCelsius: 30, expectedInterval: 15, monotonicTime: 1_020))

        let rolledBack = base.addingTimeInterval(-3_600)
        winAgg.observe(.init(date: rolledBack, trustedSystemLoad: 20, batteryChannel: .discharge(20),
                             temperatureCelsius: 35, expectedInterval: 15, monotonicTime: 1_035))
        winAgg.observe(.init(date: rolledBack.addingTimeInterval(20), trustedSystemLoad: 20, batteryChannel: .discharge(20),
                             temperatureCelsius: 35, expectedInterval: 15, monotonicTime: 1_055))
        winAgg.observe(.init(date: rolledBack.addingTimeInterval(40), trustedSystemLoad: 20, batteryChannel: .discharge(20),
                             temperatureCelsius: 35, expectedInterval: 15, monotonicTime: 1_075))
        winAgg.observe(.init(date: rolledBack.addingTimeInterval(60), trustedSystemLoad: 20, batteryChannel: .discharge(20),
                             temperatureCelsius: 35, expectedInterval: 15, monotonicTime: 1_095))

        let completedMinutes = winAgg.takeCompletedAggregates()
        let resumedMinute = try #require(completedMinutes.first { $0.windowStart == rolledBack })
        #expect(abs(resumedMinute.systemCoverage - 1.0) < 1e-9)
        #expect(abs((resumedMinute.systemPowerAverage ?? 0) - 20.0) < 1e-9)
        let priorMinute = try #require(completedMinutes.first { $0.windowStart == base })
        #expect(abs(priorMinute.systemCoverage - 20.0 / 60.0) < 1e-9)

        // 2) UsageTelemetryAggregator：回拨 1 小时后立即继续记账并累加 clockRollbackCount，不与旧桶 ID 冲突
        let utc = TimeZone(secondsFromGMT: 0)!
        var usageAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        usageAgg.observe(.init(date: base, externalConnected: false, screenOn: true, level: 80,
                               dischargePower: 6, expectedInterval: 15, timeZone: utc, monotonicTime: 1_000))
        usageAgg.observe(.init(date: base.addingTimeInterval(15), externalConnected: false, screenOn: true, level: 80,
                               dischargePower: 6, expectedInterval: 15, timeZone: utc, monotonicTime: 1_015))
        usageAgg.observe(.init(date: rolledBack, externalConnected: false, screenOn: true, level: 79,
                               dischargePower: 8, expectedInterval: 15, timeZone: utc, monotonicTime: 1_030))
        usageAgg.observe(.init(date: rolledBack.addingTimeInterval(15), externalConnected: false, screenOn: true, level: 79,
                               dischargePower: 8, expectedInterval: 15, timeZone: utc, monotonicTime: 1_045))
        usageAgg.stop(at: rolledBack.addingTimeInterval(30), monotonicTime: 1_060)

        let usageBuckets = usageAgg.takeCompleted()
        #expect(usageBuckets.allSatisfy { $0.isValid })
        #expect(usageBuckets.reduce(0) { $0 + ($1.clockRollbackCount ?? 0) } == 1)
        let resumedBucket = try #require(usageBuckets.first { $0.start == rolledBack })
        #expect(resumedBucket.screenOnSeconds == 30)
        #expect(Set(usageBuckets.map(\.id)).count == usageBuckets.count)

        // 3) 大幅前跳墙钟（>30s）必须断开连续性，不得跨跳变伪造保持时长
        var jumpAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        jumpAgg.observe(.init(date: base, externalConnected: false, screenOn: true, level: 80,
                              dischargePower: 6, expectedInterval: 15, timeZone: utc, monotonicTime: 2_000))
        jumpAgg.observe(.init(date: base.addingTimeInterval(120), externalConnected: false, screenOn: true, level: 80,
                              dischargePower: 6, expectedInterval: 15, timeZone: utc, monotonicTime: 2_005))
        jumpAgg.stop(at: base.addingTimeInterval(135), monotonicTime: 2_020)
        let jumpBuckets = jumpAgg.takeCompleted()
        #expect(jumpBuckets.reduce(0) { $0 + $1.screenOnSeconds } == 15)
    }

    @Test func continuousReadFailureSpansFiveMinuteBoundariesWhileInitialUnknownStaysOmitted() throws {
        let utc = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc

        // 初始未知态（未出现过任何已知状态）不得产出诊断桶
        var coldAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        coldAgg.observe(.init(date: base, externalConnected: nil, screenOn: true, level: 80, timeZone: utc))
        coldAgg.observe(.init(date: base.addingTimeInterval(600), externalConnected: nil, screenOn: true, level: 80, timeZone: utc))
        coldAgg.stop(at: base.addingTimeInterval(615))
        #expect(coldAgg.takeCompleted().isEmpty)

        // 运行中持续 10 分钟（600s）读取失败跨越多个 5 分钟桶边界，完整保留 600s readFailureSeconds
        var agg = UsageTelemetryAggregator(measurementEpoch: UUID())
        agg.observe(.init(date: base, externalConnected: false, screenOn: true, level: 80,
                          dischargePower: 6, expectedInterval: 15, timeZone: utc))
        agg.invalidate(at: base.addingTimeInterval(15))
        agg.observe(.init(date: base.addingTimeInterval(615), externalConnected: false, screenOn: true, level: 78,
                          dischargePower: 6, expectedInterval: 15, timeZone: utc))
        agg.stop(at: base.addingTimeInterval(630))

        let buckets = agg.takeCompleted()
        #expect(buckets.allSatisfy { $0.isValid })
        #expect(buckets.reduce(0) { $0 + ($1.readFailureSeconds ?? 0) } == 600)
        #expect(buckets.contains { $0.knownSeconds == 0 && ($0.readFailureSeconds ?? 0) == 300 })

        // 纯诊断桶（knownSeconds == 0）不得在 UsageDailyStore 制造虚假日汇总
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-readfail-daily-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let dailyStore = UsageDailyStore(directory: dir)
        let diagOnly = try #require(buckets.first { $0.knownSeconds == 0 })
        dailyStore.include(diagOnly)
        #expect(dailyStore.read().isEmpty)
    }

    @Test func corruptRetainedDailyCheckpointRecoversSummaryInMemoryWithoutOverwritingFile() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("bb-corrupt-recover-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = base.addingTimeInterval(600)
        let store = UsageHistoryStore(directory: dir, now: now)
        let epoch = store.measurementEpoch
        var b1 = UsageBucket(
            measurementEpoch: epoch, runID: UUID(), timeZoneID: "GMT",
            start: base, end: base.addingTimeInterval(300),
            screenOnSeconds: 300, dischargeWh: 0.5, powerSeconds: 300
        )
        b1.spans = [UsageSpan(start: base, end: base.addingTimeInterval(300), activity: .batteryScreenOn,
                              sessionID: UUID(), continuityID: UUID(), dischargeWh: 0.5, powerSeconds: 300)]
        store.append([b1], now: now)

        let dailyDir = dir.appendingPathComponent("usage-daily")
        let checkpoint = try #require(FileManager.default.contentsOfDirectory(
            at: dailyDir, includingPropertiesForKeys: nil
        ).first)
        let corruptBytes = Data("corrupt-daily-checkpoint".utf8)
        try corruptBytes.write(to: checkpoint)

        let restored = UsageHistoryStore(directory: dir, now: now)
        let page = restored.read(in: DateInterval(start: base, end: now), now: now)
        #expect(page.error != nil)
        #expect(try Data(contentsOf: checkpoint) == corruptBytes)
        let recovered = try #require(restored.dailySummaries().first)
        #expect(recovered.screenOnSeconds == 300)
        #expect(abs(recovered.dischargeWh - 0.5) < 1e-9)
    }

    @Test func incompleteSessionBoundariesDisableSessionRankingEvenAtFullCoverage() {
        let utc = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = utc

        // 1) startIncomplete == true（启动已在离电，但插电终点已观测且功率覆盖 100%）→ canRankSessions 必须为 false
        var startMissingAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        startMissingAgg.observe(.init(date: base, externalConnected: false, screenOn: true, level: 80, dischargePower: 6, timeZone: utc))
        startMissingAgg.observe(.init(date: base.addingTimeInterval(15), externalConnected: true, screenOn: true, level: 80, timeZone: utc))
        startMissingAgg.stop(at: base.addingTimeInterval(30))
        let startMissingReview = UsageHistoryAnalysis.reviews(
            stored: startMissingAgg.takeCompleted(), live: [], dates: [base], calendar: cal, now: base.addingTimeInterval(60)
        )[0]
        #expect(startMissingReview.sessions.first?.coverage == 1.0)
        #expect(startMissingReview.sessions.first?.startIncomplete == true)
        #expect(!startMissingReview.canRankSessions)

        // 2) endIncomplete == true（观测到拔电但因休眠截断，覆盖 100%）→ canRankSessions 必须为 false
        var endMissingAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        endMissingAgg.observe(.init(date: base, externalConnected: true, screenOn: true, level: 80, timeZone: utc))
        endMissingAgg.observe(.init(date: base.addingTimeInterval(15), externalConnected: false, screenOn: true, level: 80, dischargePower: 6, timeZone: utc))
        endMissingAgg.sleep(at: base.addingTimeInterval(30))
        endMissingAgg.wake(at: base.addingTimeInterval(60))
        endMissingAgg.stop(at: base.addingTimeInterval(60))
        let endMissingReview = UsageHistoryAnalysis.reviews(
            stored: endMissingAgg.takeCompleted(), live: [], dates: [base], calendar: cal, now: base.addingTimeInterval(120)
        )[0]
        #expect(endMissingReview.sessions.first?.coverage == 1.0)
        #expect(endMissingReview.sessions.first?.endIncomplete == true)
        #expect(!endMissingReview.canRankSessions)

        // 3) 起止边界完整且覆盖 100% 的已结束时段 → canRankSessions 为 true
        var completeAgg = UsageTelemetryAggregator(measurementEpoch: UUID())
        completeAgg.observe(.init(date: base, externalConnected: true, screenOn: true, level: 80, timeZone: utc))
        completeAgg.observe(.init(date: base.addingTimeInterval(15), externalConnected: false, screenOn: true, level: 80, dischargePower: 6, timeZone: utc))
        completeAgg.observe(.init(date: base.addingTimeInterval(30), externalConnected: true, screenOn: true, level: 80, timeZone: utc))
        completeAgg.stop(at: base.addingTimeInterval(45))
        let completeReview = UsageHistoryAnalysis.reviews(
            stored: completeAgg.takeCompleted(), live: [], dates: [base], calendar: cal, now: base.addingTimeInterval(60)
        )[0]
        #expect(completeReview.canRankSessions)
    }

    @Test func trendDownsamplerPreservesOneMinuteSpikeAndBreakBeforeAcrossTwentyFourHours() {
        let spikeIndex = 723
        let gapIndex = 500
        let points = (0..<1_440).map { minute in
            TrendPoint(
                time: base.addingTimeInterval(Double(minute * 60)),
                value: minute == spikeIndex ? 98.0 : 10.0,
                breakBefore: minute == gapIndex
            )
        }
        let sampled = ChartDownsampler.downsampleTrendPoints(points, maxPoints: 240)
        #expect(sampled.count <= 240)
        #expect(sampled.first?.time == points.first?.time)
        #expect(sampled.last?.time == points.last?.time)
        #expect(sampled.contains { $0.value == 98.0 })
        #expect(sampled.contains { $0.breakBefore && $0.time == points[gapIndex].time })
        #expect(zip(sampled, sampled.dropFirst()).allSatisfy { $0.time < $1.time })
    }
}
