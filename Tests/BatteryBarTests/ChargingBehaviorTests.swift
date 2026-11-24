import Foundation
import Testing
@testable import BatteryBar

@Suite struct ChargingBehaviorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("五档上限达标只表达事实，不伪造优化原因")
    func targetReachedPresentation() {
        for target in ChargeLimitTarget.allCases {
            let label = ChargingStatusPresentation.pluggedNotChargingLabel(
                observation: nil, level: Double(target.rawValue), targetPercent: target.rawValue
            )
            #expect(!label.contains("原因未确认"))
            #expect(!label.contains("优化"))
            #expect(label.contains(target == .percent100 ? "已充满" : "\(target.rawValue)%"))
        }
        #expect(ChargingStatusPresentation.pluggedNotChargingLabel(
            observation: nil, level: 79, targetPercent: 80
        ) == "已接电，未充电")
        #expect(ChargingStatusPresentation.pluggedNotChargingLabel(
            observation: nil, level: 80, targetPercent: nil
        ) == "已接电，未充电")
        let thermal = ChargingBehaviorObservation.resolve(
            isPluggedIn: true, isCharging: false, chargeStatus: "HighTemperature", observedAt: now
        )
        #expect(ChargingStatusPresentation.pluggedNotChargingLabel(
            observation: thermal, level: 80, targetPercent: 80
        ).contains("温度保护"))
    }

    @Test("仅公开IsCharging=true显示观察到的充电")
    func chargingSignalWinsOverPauseHint() throws {
        let observation = try #require(ChargingBehaviorObservation.resolve(
            isPluggedIn: true,
            isCharging: true,
            chargeStatus: "HighTemperature",
            observedAt: now
        ))
        #expect(observation.state == .observedCharging)
        #expect(observation.reason == nil)
        #expect(observation.source == "IOPowerSources Is Charging")
    }

    @Test("已知公开温度状态与未充电同时出现时记录其他暂停")
    func publicThermalStatusExplainsNotCharging() throws {
        let observation = try #require(ChargingBehaviorObservation.resolve(
            isPluggedIn: true,
            isCharging: false,
            chargeStatus: "HighOrLowTemperature",
            observedAt: now
        ))
        #expect(observation.state == .otherConfirmedPause)
        #expect(observation.reason == .thermalProtection)
        #expect(observation.displayLabel.contains("温度保护"))
        #expect(observation.observedAt == now)
    }

    @Test("未知原因位值、零功率或接近80%不能判为优化暂缓")
    func unknownNotChargingReasonDoesNotImplyOptimizationPause() throws {
        let observation = try #require(ChargingBehaviorObservation.resolve(
            isPluggedIn: true,
            isCharging: false,
            chargeStatus: "NotChargingReason=2",
            observedAt: now
        ))
        #expect(observation.state == .reasonUnknown)
        #expect(observation.displayLabel == "未充电 · 原因未确认")

        // 已配置80%目标本身不会让运行态resolver认定优化暂停。
        let policy = ChargePolicySnapshot(status: .configured, targetPercent: 80,
                                          source: ChargePolicySnapshot.sourceName, readAt: now)
        #expect(policy.targetPercent == 80)
        #expect(ChargingBehaviorObservation.resolve(
            isPluggedIn: true, isCharging: false, chargeStatus: nil, observedAt: now
        )?.state == .reasonUnknown)
    }

    @Test("离电状态不生成接电行为观察")
    func unpluggedDoesNotCreateChargeObservation() {
        #expect(ChargingBehaviorObservation.resolve(
            isPluggedIn: false,
            isCharging: false,
            chargeStatus: "HighTemperature",
            observedAt: now
        ) == nil)
    }

    @Test("充电启动本身和79%停充不产生完成证据")
    func startupAndNearTargetDoNotProduceCompletion() {
        var tracker = ChargeCompletionTracker()
        #expect(tracker.observe(pluggedIn: true, isCharging: false, level: 79,
                                targetPercent: 80, policyRevision: 1) == nil) // 启动基线
        #expect(tracker.observe(pluggedIn: true, isCharging: false, level: 79,
                                targetPercent: 80, policyRevision: 1) == nil)

        #expect(tracker.observe(pluggedIn: true, isCharging: true, level: 79,
                                targetPercent: 80, policyRevision: 1) == nil)
        #expect(tracker.observe(pluggedIn: true, isCharging: false, level: 79,
                                targetPercent: 80, policyRevision: 1) == nil)
    }

    @Test("同一接电阶段从79%充到80%才产生完成证据")
    func targetCrossingWithinOnePlugSessionProducesEvidence() throws {
        var tracker = ChargeCompletionTracker()
        _ = tracker.observe(pluggedIn: true, isCharging: false, level: 79,
                            targetPercent: 80, policyRevision: 3)
        #expect(tracker.observe(pluggedIn: true, isCharging: true, level: 79,
                                targetPercent: 80, policyRevision: 3) == nil)
        let completed = tracker.observe(
            pluggedIn: true, isCharging: false, level: 80,
            targetPercent: 80, policyRevision: 3
        )
        let evidence = try #require(completed)
        #expect(evidence.targetPercent == 80)
        #expect(evidence.startLevel == 79)
        #expect(evidence.policyRevision == 3)
    }

    @Test("拔电或修改上限使完成候选失效")
    func unplugOrPolicyChangeInvalidatesCandidate() {
        var unplugged = ChargeCompletionTracker()
        _ = unplugged.observe(pluggedIn: true, isCharging: false, level: 79,
                              targetPercent: 80, policyRevision: 3)
        _ = unplugged.observe(pluggedIn: true, isCharging: true, level: 79,
                              targetPercent: 80, policyRevision: 3)
        #expect(unplugged.observe(pluggedIn: false, isCharging: false, level: 80,
                                  targetPercent: 80, policyRevision: 3) == nil)

        var changed = ChargeCompletionTracker()
        _ = changed.observe(pluggedIn: true, isCharging: false, level: 79,
                            targetPercent: 80, policyRevision: 3)
        _ = changed.observe(pluggedIn: true, isCharging: true, level: 79,
                            targetPercent: 80, policyRevision: 3)
        #expect(changed.observe(pluggedIn: true, isCharging: false, level: 80,
                                targetPercent: 90, policyRevision: 4) == nil)
    }
}
