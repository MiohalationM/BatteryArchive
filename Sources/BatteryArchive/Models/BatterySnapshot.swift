import Foundation

/// 本地每分钟电池采样快照（保留 24 小时，仅服务实时分析页历史趋势与续航/充电估算）。
///
/// 功率口径：
/// - `wattage`：系统负载（瓦特），仅在缺少分钟聚合时的旧版回退路径消费；
/// - `isCharging` 只表达电池包是否正在充入；`externalConnected == nil` 表示来源未知，绝不用 `!isCharging` 反推离电；
/// - 分钟聚合字段（`aggregateWindowStart` 及系统能耗/平均/峰值/覆盖率、温度均值/最大值/覆盖率）均采用 `encodeIfPresent`，
///   兼容解码磁盘上历史遗留的多余键（自动忽略不再需要的旧字段）。
struct BatterySnapshot: Codable, Identifiable, Equatable, Sendable {
    var id: UUID
    var timestamp: Date
    var level: Double          // 0~100
    var isCharging: Bool       // 仅表示电池包正在充入
    var wattage: Double        // 系统负载（瓦特；旧数据无分钟聚合时的回退读数）
    var systemPowerAvailable: Bool
    var systemPowerIsEstimated: Bool
    /// 是否接外接电源。nil = 来源未知；禁止用 !isCharging 回填推断。
    var externalConnected: Bool?

    // MARK: 分钟聚合（全部可选；nil = 无达标聚合或旧格式数据）
    /// 聚合所属自然分钟窗口起点
    var aggregateWindowStart: Date?
    var systemEnergyWh: Double?
    var systemPowerAverage: Double?
    var systemPowerPeak: Double?
    var systemCoverage: Double?
    /// 按有效时长加权的温度均值（非样本算术平均）
    var temperatureAverage: Double?
    var temperatureMaximum: Double?
    var temperatureCoverage: Double?

    init(
        timestamp: Date,
        level: Double,
        isCharging: Bool,
        wattage: Double,
        systemPowerAvailable: Bool? = nil,
        systemPowerIsEstimated: Bool? = nil,
        externalConnected: Bool? = nil
    ) {
        self.id = UUID()
        self.timestamp = timestamp
        self.level = level
        self.isCharging = isCharging
        self.wattage = wattage
        self.systemPowerAvailable = systemPowerAvailable ?? !isCharging
        self.systemPowerIsEstimated = systemPowerIsEstimated ?? true
        self.externalConnected = externalConnected
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        timestamp = try c.decode(Date.self, forKey: .timestamp)
        level = try c.decode(Double.self, forKey: .level)
        isCharging = try c.decode(Bool.self, forKey: .isCharging)
        wattage = try c.decodeIfPresent(Double.self, forKey: .wattage) ?? 0
        systemPowerAvailable = try c.decodeIfPresent(Bool.self, forKey: .systemPowerAvailable) ?? !isCharging
        systemPowerIsEstimated = try c.decodeIfPresent(Bool.self, forKey: .systemPowerIsEstimated) ?? true
        externalConnected = try c.decodeIfPresent(Bool.self, forKey: .externalConnected)
        aggregateWindowStart = try c.decodeIfPresent(Date.self, forKey: .aggregateWindowStart)
        systemEnergyWh = try c.decodeIfPresent(Double.self, forKey: .systemEnergyWh)
        systemPowerAverage = try c.decodeIfPresent(Double.self, forKey: .systemPowerAverage)
        systemPowerPeak = try c.decodeIfPresent(Double.self, forKey: .systemPowerPeak)
        systemCoverage = try c.decodeIfPresent(Double.self, forKey: .systemCoverage)
        temperatureAverage = try c.decodeIfPresent(Double.self, forKey: .temperatureAverage)
        temperatureMaximum = try c.decodeIfPresent(Double.self, forKey: .temperatureMaximum)
        temperatureCoverage = try c.decodeIfPresent(Double.self, forKey: .temperatureCoverage)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(timestamp, forKey: .timestamp)
        try c.encode(level, forKey: .level)
        try c.encode(isCharging, forKey: .isCharging)
        try c.encode(wattage, forKey: .wattage)
        try c.encode(systemPowerAvailable, forKey: .systemPowerAvailable)
        try c.encode(systemPowerIsEstimated, forKey: .systemPowerIsEstimated)
        // encodeIfPresent：键缺失即代表来源未知，不伪造电源状态
        try c.encodeIfPresent(externalConnected, forKey: .externalConnected)
        try c.encodeIfPresent(aggregateWindowStart, forKey: .aggregateWindowStart)
        try c.encodeIfPresent(systemEnergyWh, forKey: .systemEnergyWh)
        try c.encodeIfPresent(systemPowerAverage, forKey: .systemPowerAverage)
        try c.encodeIfPresent(systemPowerPeak, forKey: .systemPowerPeak)
        try c.encodeIfPresent(systemCoverage, forKey: .systemCoverage)
        try c.encodeIfPresent(temperatureAverage, forKey: .temperatureAverage)
        try c.encodeIfPresent(temperatureMaximum, forKey: .temperatureMaximum)
        try c.encodeIfPresent(temperatureCoverage, forKey: .temperatureCoverage)
    }

    private enum CodingKeys: String, CodingKey {
        case id, timestamp, level, isCharging, wattage
        case systemPowerAvailable, systemPowerIsEstimated, externalConnected
        case aggregateWindowStart, systemEnergyWh, systemPowerAverage, systemPowerPeak, systemCoverage
        case temperatureAverage, temperatureMaximum, temperatureCoverage
    }

    /// 可信的系统负载。
    /// 实测遥测（estimated == false）独立可信，无论电源状态如何都保留；
    /// 估算负载只有在**明确离电**时才可信——来源未知的估算点可能是
    /// "接电未充电"被误标的历史污染（满电/充电上限），保守排除。
    var trustedSystemLoad: Double? {
        guard systemPowerAvailable, wattage > 0 else { return nil }
        if !systemPowerIsEstimated { return wattage }
        return externalConnected == false ? wattage : nil
    }

    /// 把一个已完成分钟窗口的聚合写入快照。
    /// 覆盖率未达标的量保持 nil（不伪造完整分钟指标）；
    /// 温度最大值在覆盖率不足时仍保留，由 temperatureCoverage 附带说明。
    mutating func apply(minuteAggregate aggregate: MinuteAggregate) {
        aggregateWindowStart = aggregate.windowStart
        systemEnergyWh = aggregate.hasFullSystemMetric ? aggregate.systemEnergyWh : nil
        systemPowerAverage = aggregate.hasFullSystemMetric ? aggregate.systemPowerAverage : nil
        systemPowerPeak = aggregate.hasFullSystemMetric ? aggregate.systemPowerPeak : nil
        systemCoverage = aggregate.systemCoverage
        // 温度：coverage<0.5 时趋势均值不可用于连线（置 nil），
        // 但只要该分钟确实观察到温度，最大值必须保留并附带覆盖率。
        if aggregate.hasUsableTemperatureTrend {
            temperatureAverage = aggregate.temperatureAverage
            temperatureMaximum = aggregate.temperatureMaximum
        } else {
            temperatureAverage = nil
            temperatureMaximum = aggregate.temperatureMaximum
        }
        temperatureCoverage = aggregate.temperatureCoverage
    }
}
