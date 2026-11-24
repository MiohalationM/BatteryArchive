import Foundation

/// 通知触发策略（纯逻辑，无 UserNotifications / 系统权限依赖）。
///
/// 低电量与充电目标提醒的全部触发门槛、冷却窗口在这里裁决；冷却时间戳由调用方
/// 持久化（UserDefaults），因此 BA 重启后依然遵守冷却窗口。
///
/// 低电量禁止情形（满足任一即不触发）：
/// - 外接电源明确接上（externalConnected == true）
/// - 外接电源状态未知（externalConnected == nil）
/// - 当前正在充电
/// - 低电量开关关闭 / 通知权限无效
///
/// 目标提醒前提：外接电源明确接上、前一状态明确正在充电、当前已停止充电、
/// 同一充电阶段从低于可靠目标达到目标、策略版本未变化、开关/权限/冷却有效。
enum NotificationPolicy {
    /// 低电量提醒电量阈值
    static let lowBatteryThreshold: Double = 20
    /// 低电量提醒冷却窗口（30 分钟）
    static let lowBatteryCooldown: TimeInterval = 30 * 60
    /// 充满提醒冷却窗口（60 分钟）
    static let fullChargeCooldown: TimeInterval = 60 * 60
    /// 低电量是否应当触发。
    /// - Parameters:
    ///   - externalConnected: 是否接外接电源；nil 表示来源未知（禁止触发）
    ///   - lastNotificationAt: 上次低电量通知时间（nil = 从未通知，视为冷却已结束）
    static func shouldSendLowBattery(
        level: Double,
        externalConnected: Bool?,
        isCharging: Bool,
        lowBatteryEnabled: Bool,
        permissionValid: Bool,
        lastNotificationAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard lowBatteryEnabled, permissionValid else { return false }
        guard externalConnected == false else { return false }
        guard !isCharging else { return false }
        guard level <= lowBatteryThreshold else { return false }
        return cooldownElapsed(last: lastNotificationAt, cooldown: lowBatteryCooldown, now: now)
    }

    /// 充电目标是否应当触发。
    static func shouldSendFullCharge(
        level: Double,
        externalConnected: Bool?,
        wasCharging: Bool,
        isCharging: Bool,
        targetPercent: Int?,
        completionEvidence: ChargeCompletionEvidence?,
        policyRevision: Int,
        fullChargeEnabled: Bool,
        permissionValid: Bool,
        lastNotificationAt: Date?,
        now: Date = Date()
    ) -> Bool {
        guard fullChargeEnabled, permissionValid else { return false }
        guard externalConnected == true else { return false }
        guard wasCharging else { return false }
        guard !isCharging else { return false }
        guard let targetPercent, ChargeLimitTarget(rawValue: targetPercent) != nil,
              let completionEvidence,
              completionEvidence.targetPercent == targetPercent,
              completionEvidence.policyRevision == policyRevision,
              completionEvidence.startLevel < Double(targetPercent),
              level >= Double(targetPercent) else { return false }
        return cooldownElapsed(last: lastNotificationAt, cooldown: fullChargeCooldown, now: now)
    }

    /// 冷却窗口是否已结束（时钟回拨导致 elapsed < 0 时按冷却结束处理，避免永久静默）。
    static func cooldownElapsed(last: Date?, cooldown: TimeInterval, now: Date) -> Bool {
        guard let last else { return true }
        let elapsed = now.timeIntervalSince(last)
        return elapsed < 0 || elapsed >= cooldown
    }
}
