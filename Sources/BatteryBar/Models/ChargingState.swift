import Foundation

/// 达到配置目标是可观察事实，与系统为何停充是两个维度。
enum ChargingStatusPresentation {
    static func pluggedNotChargingLabel(
        observation: ChargingBehaviorObservation?,
        level: Double,
        targetPercent: Int?
    ) -> String {
        if let observation, observation.state == .otherConfirmedPause {
            return observation.displayLabel
        }
        if let targetPercent, (80...100).contains(targetPercent),
           level.isFinite, level >= Double(targetPercent) {
            return targetPercent == 100 ? "电池已充满 · 接电供电" : "已达设定上限 \(targetPercent)% · 接电供电"
        }
        return "已接电，未充电"
    }
}

/// 电池包充电行为（仅反映公开 IOPS / IOPM 可证实的充电或暂停原因）。
enum ChargingBehaviorState: String, Codable, Equatable, Sendable {
    case observedCharging
    case otherConfirmedPause
    case reasonUnknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .reasonUnknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayLabel: String {
        switch self {
        case .observedCharging: "正在充电"
        case .otherConfirmedPause: "系统已暂停充电"
        case .reasonUnknown: "未充电 · 原因未确认"
        }
    }
}

enum ChargingPauseReason: String, Codable, Equatable, Sendable {
    case thermalProtection
    case unknown

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        self = Self(rawValue: try container.decode(String.self)) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    var displayLabel: String {
        switch self {
        case .thermalProtection: "温度保护"
        case .unknown: "原因未确认"
        }
    }
}

/// 一次实时行为观察。`observedAt` 是 App 完成本轮系统读取的时刻。
struct ChargingBehaviorObservation: Codable, Equatable, Sendable {
    var state: ChargingBehaviorState
    var reason: ChargingPauseReason?
    var source: String
    var observedAt: Date

    var displayLabel: String {
        if state == .otherConfirmedPause {
            return reason == .thermalProtection ? "因温度保护暂停充电" : "系统已暂停充电"
        }
        return state.displayLabel
    }

    /// 只消费公开 IOPowerSources 的 Is Charging 与公开 IOPM ChargeStatus。
    /// 未充电本身、功率为零、电量接近某个上限或限值策略存在都不足以确认优化暂停。
    static func resolve(
        isPluggedIn: Bool,
        isCharging: Bool,
        chargeStatus: String?,
        observedAt: Date
    ) -> ChargingBehaviorObservation? {
        guard isPluggedIn else { return nil }
        if isCharging {
            return ChargingBehaviorObservation(
                state: .observedCharging,
                reason: nil,
                source: "IOPowerSources Is Charging",
                observedAt: observedAt
            )
        }

        // IOPM.h 定义的公开 ChargeStatus 值表示可能中断充电；仅在同一读取明确
        // 显示 IsCharging=false 时归为其他暂停。未知值（包括 NotChargingReason 位值）不推断。
        if Self.thermalChargeStatuses.contains(chargeStatus ?? "") {
            return ChargingBehaviorObservation(
                state: .otherConfirmedPause,
                reason: .thermalProtection,
                source: "IOPowerSources Is Charging + IOPM ChargeStatus",
                observedAt: observedAt
            )
        }

        return ChargingBehaviorObservation(
            state: .reasonUnknown,
            reason: .unknown,
            source: "IOPowerSources Is Charging=false; pause cause unavailable",
            observedAt: observedAt
        )
    }

    private static let thermalChargeStatuses: Set<String> = [
        "HighTemperature",
        "LowTemperature",
        "HighOrLowTemperature",
        "BatteryTemperatureGradient",
    ]
}
