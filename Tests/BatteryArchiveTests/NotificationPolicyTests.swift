import Foundation
import Testing
@testable import BatteryArchive

/// 通知触发策略纯逻辑反例：不依赖 UserNotifications / 系统权限，
/// 冷却窗口使用外部注入的时间戳（由调用方持久化，重启后依然生效）。
@Suite struct NotificationPolicyTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func completion(_ target: Int = 100, revision: Int = 1, startLevel: Double = 99) -> ChargeCompletionEvidence {
        ChargeCompletionEvidence(targetPercent: target, policyRevision: revision, startLevel: startLevel)
    }

    // MARK: - 低电量

    @Test("明确离电且低电量可以触发")
    func lowBatteryFiresWhenDisconnected() {
        #expect(NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("接电未充电禁止低电量提醒")
    func lowBatteryBlockedWhenPluggedNotCharging() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: true,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("正在充电禁止低电量提醒")
    func lowBatteryBlockedWhileCharging() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: true,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("电源来源未知禁止低电量提醒")
    func lowBatteryBlockedWhenSourceUnknown() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: nil,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("电量高于阈值禁止低电量提醒")
    func lowBatteryBlockedAboveThreshold() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 21,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("用户关闭低电量开关后策略拒绝触发")
    func lowBatteryBlockedWhenToggleOff() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: false,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("权限无效禁止低电量提醒")
    func lowBatteryBlockedWhenPermissionInvalid() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: false,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("冷却窗口未结束禁止低电量提醒")
    func lowBatteryBlockedByCooldown() {
        #expect(!NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: now.addingTimeInterval(-100),
            now: now
        ))
    }

    @Test("冷却窗口结束后允许再次提醒")
    func lowBatteryAllowedAfterCooldown() {
        #expect(NotificationPolicy.shouldSendLowBattery(
            level: 15,
            externalConnected: false,
            isCharging: false,
            lowBatteryEnabled: true,
            permissionValid: true,
            lastNotificationAt: now.addingTimeInterval(-NotificationPolicy.lowBatteryCooldown - 1),
            now: now
        ))
    }

    // MARK: - 充满

    @Test("充满提醒要求外接电源为 true")
    func fullChargeRequiresExternalConnected() {
        let base = { (external: Bool?) in
            NotificationPolicy.shouldSendFullCharge(
                level: 100,
                externalConnected: external,
                wasCharging: true,
                isCharging: false,
                targetPercent: 100,
                completionEvidence: completion(),
                policyRevision: 1,
                fullChargeEnabled: true,
                permissionValid: true,
                lastNotificationAt: nil,
                now: now
            )
        }
        #expect(base(nil) == false)
        #expect(base(false) == false)
        #expect(base(true) == true)
    }

    @Test("充满提醒要求前一状态明确正在充电")
    func fullChargeRequiresPreviousCharging() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: false,
            isCharging: false,
            targetPercent: 100,
            completionEvidence: completion(),
            policyRevision: 1,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒要求当前状态停止充电")
    func fullChargeRequiresNotChargingNow() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: true,
            targetPercent: 100,
            completionEvidence: completion(),
            policyRevision: 1,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒要求达到充满门槛")
    func fullChargeRequiresFullLevel() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 99,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            targetPercent: 100,
            completionEvidence: completion(),
            policyRevision: 1,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒全条件满足可以触发")
    func fullChargeFiresWhenAllConditionsMet() {
        #expect(NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            targetPercent: 100,
            completionEvidence: completion(),
            policyRevision: 1,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒用户关闭后策略拒绝触发")
    func fullChargeBlockedWhenToggleOff() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            targetPercent: 100,
            completionEvidence: completion(),
            policyRevision: 1,
            fullChargeEnabled: false,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("充满提醒冷却窗口未结束禁止触发")
    func fullChargeBlockedByCooldown() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            targetPercent: 100,
            completionEvidence: completion(),
            policyRevision: 1,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: now.addingTimeInterval(-60),
            now: now
        ))
    }

    @Test("上限目标未知时不回退到100%并且不通知")
    func unknownTargetCannotTriggerFullChargeNotification() {
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            targetPercent: nil,
            completionEvidence: nil,
            policyRevision: 0,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("80%上限通知必须从低于目标的充电阶段跨到目标")
    func configuredTargetRequiresActualCrossing() {
        let evidence = completion(80, revision: 4, startLevel: 79)
        let shared: (Double, Int) -> Bool = { level, revision in
            NotificationPolicy.shouldSendFullCharge(
                level: level,
                externalConnected: true,
                wasCharging: true,
                isCharging: false,
                targetPercent: 80,
                completionEvidence: evidence,
                policyRevision: revision,
                fullChargeEnabled: true,
                permissionValid: true,
                lastNotificationAt: nil,
                now: self.now
            )
        }
        #expect(!shared(79, 4))
        #expect(shared(80, 4))
        #expect(!shared(80, 5)) // 上限策略在充电期间改动
    }

    @Test("确认无上限（.noActiveLimit）观察到充电至 100% 停充时触发充满提醒，已满接电不误报")
    func noActiveLimitFiresOnObservedFullChargeAndBlocksAlreadyFullPlugIn() throws {
        let policy = ChargePolicyParser.parse(
            .init(stdout: "No battery level limits set\n", exitCode: 0),
            readAt: now
        )
        #expect(policy.status == .noActiveLimit)
        #expect(policy.targetPercent == nil)
        let target = try #require(policy.completionNotificationTargetPercent)
        #expect(target == 100)

        // 正常场景：接电开始充电（98%）→ 充到 100% 停充
        var tracker = ChargeCompletionTracker()
        let baseline = tracker.observe(pluggedIn: false, isCharging: false, level: 98, targetPercent: target, policyRevision: 1)
        #expect(baseline == nil)
        let started = tracker.observe(pluggedIn: true, isCharging: true, level: 98, targetPercent: target, policyRevision: 1)
        #expect(started == nil)
        let observedCompletion = tracker.observe(pluggedIn: true, isCharging: false, level: 100, targetPercent: target, policyRevision: 1)
        let evidence = try #require(observedCompletion)
        #expect(evidence == ChargeCompletionEvidence(targetPercent: 100, policyRevision: 1, startLevel: 98))
        #expect(NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            targetPercent: target,
            completionEvidence: evidence,
            policyRevision: 1,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))

        // 反例：已满 100% 时直接接电，无 charging -> stopped 过渡，绝不误报
        var alreadyFullTracker = ChargeCompletionTracker()
        let alreadyFullBaseline = alreadyFullTracker.observe(pluggedIn: false, isCharging: false, level: 100, targetPercent: target, policyRevision: 1)
        #expect(alreadyFullBaseline == nil)
        let alreadyFullEvidence = alreadyFullTracker.observe(
            pluggedIn: true, isCharging: false, level: 100, targetPercent: target, policyRevision: 1
        )
        #expect(alreadyFullEvidence == nil)
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: false,
            isCharging: false,
            targetPercent: target,
            completionEvidence: alreadyFullEvidence,
            policyRevision: 1,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }

    @Test("策略过期/不可用/未知/冲突时 completionNotificationTargetPercent 为 nil 且永不触发提醒")
    func uncertainPoliciesNeverFireFullChargeNotification() {
        let ttl: TimeInterval = 900
        let noLimit = ChargePolicyParser.parse(.init(stdout: "No battery level limits set\n", exitCode: 0), readAt: now)
        let stale = noLimit.expiring(at: now.addingTimeInterval(ttl), ttl: ttl)
        let unavailable = ChargePolicySnapshot.unavailable(readAt: now)
        let unknown = ChargePolicyParser.parse(.init(stdout: "Battery level limits: <unknown>", exitCode: 0), readAt: now)
        let conflict = ChargePolicyParser.parse(.init(stdout: """
        Battery level limits:
        (
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 80; },
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 90; }
        )
        """, exitCode: 0), readAt: now)

        for policy in [stale, unavailable, unknown, conflict] {
            #expect(policy.completionNotificationTargetPercent == nil)
            var tracker = ChargeCompletionTracker()
            _ = tracker.observe(pluggedIn: false, isCharging: false, level: 98, targetPercent: policy.completionNotificationTargetPercent, policyRevision: 2)
            _ = tracker.observe(pluggedIn: true, isCharging: true, level: 98, targetPercent: policy.completionNotificationTargetPercent, policyRevision: 2)
            let evidence = tracker.observe(pluggedIn: true, isCharging: false, level: 100, targetPercent: policy.completionNotificationTargetPercent, policyRevision: 2)
            #expect(evidence == nil)
            #expect(!NotificationPolicy.shouldSendFullCharge(
                level: 100,
                externalConnected: true,
                wasCharging: true,
                isCharging: false,
                targetPercent: policy.completionNotificationTargetPercent,
                completionEvidence: evidence,
                policyRevision: 2,
                fullChargeEnabled: true,
                permissionValid: true,
                lastNotificationAt: nil,
                now: now
            ))
        }

        // 起充时确认无上限，但停充瞬间策略已过期（stale）→ 同样阻断提醒
        var expiringTracker = ChargeCompletionTracker()
        _ = expiringTracker.observe(pluggedIn: false, isCharging: false, level: 98, targetPercent: noLimit.completionNotificationTargetPercent, policyRevision: 3)
        _ = expiringTracker.observe(pluggedIn: true, isCharging: true, level: 98, targetPercent: noLimit.completionNotificationTargetPercent, policyRevision: 3)
        let expiredEvidence = expiringTracker.observe(pluggedIn: true, isCharging: false, level: 100, targetPercent: stale.completionNotificationTargetPercent, policyRevision: 3)
        #expect(expiredEvidence == nil)
        #expect(!NotificationPolicy.shouldSendFullCharge(
            level: 100,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            targetPercent: stale.completionNotificationTargetPercent,
            completionEvidence: expiredEvidence,
            policyRevision: 3,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: now
        ))
    }
}
