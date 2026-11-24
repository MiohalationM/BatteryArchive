import Foundation

/// 一个自然分钟窗口的聚合结果（仅保留实时分析趋势与续航估算真实消费的连续量字段）。
/// - 能量只来自可信来源的零阶保持积分，缺口不外推；
/// - `systemCoverage` / `temperatureCoverage` 是「有效时长 / 60 秒」，有效零瓦计入覆盖，缺失不计入；
/// - `batteryChargeSeconds` 用于确认离电窗口内无充电混入。
struct MinuteAggregate: Equatable {
    var windowStart: Date

    var systemEnergyWh: Double?
    var systemPowerAverage: Double?
    var systemPowerPeak: Double?
    var systemCoverage: Double

    var batteryChargeSeconds: TimeInterval
    var batteryDischargeWh: Double
    var batteryDischargeSeconds: TimeInterval

    var temperatureAverage: Double?
    var temperatureMaximum: Double?
    var temperatureCoverage: Double

    /// 窗口内净充入电池包的累计能量（Wh）；默认 0 保持既有构造调用兼容。
    var batteryChargeWh: Double = 0

    /// UI 是否可把能耗当作完整分钟指标展示（冻结阈值：覆盖率 ≥ 0.8）。
    var hasFullSystemMetric: Bool { systemCoverage >= 0.8 }
    /// 温度趋势是否允许连线（冻结阈值：覆盖率 ≥ 0.5）；最大值可保留但须附覆盖率。
    var hasUsableTemperatureTrend: Bool { temperatureCoverage >= 0.5 }
}

/// 分钟窗口遥测聚合器：纯逻辑、时间显式注入、常量内存。
///
/// 连续量（系统负载、电池充/放功率、温度）采用上一有效观测值零阶保持，
/// 单个样本最多保持 `min(30秒, 2×取得该样本时的预期间隔)`；超过部分视为缺口，
/// 严禁跨长时间无样本外推。负时间、乱序时间整条观测拒绝。
/// 睡眠开始调用 `truncateContinuity` 立即截断连续量。
struct WindowTelemetryAggregator {
    static let windowLength: TimeInterval = 60
    static let maximumHold: TimeInterval = 30

    enum BatteryChannel: Equatable {
        /// 接电且 isCharging==true：电池包净流入功率（瓦特）
        case charge(Double)
        /// 明确离电：电池包放出功率绝对值（瓦特）
        case discharge(Double)
        /// 电源方向未知：不得进入任何一侧积分
        case unknown
    }

    struct Observation {
        let date: Date
        /// 可信系统负载；nil 为缺口，`.some(0)` 是合法零瓦
        let trustedSystemLoad: Double?
        let batteryChannel: BatteryChannel
        /// 有效电池包温度；nil 表示本轮不可读
        let temperatureCelsius: Double?
        /// 取得本批样本时的预期间隔（前台 5s / 后台 15s），决定保持上限
        let expectedInterval: TimeInterval
        /// 单调时钟读数（如 `ProcessInfo.processInfo.systemUptime`），用于区分真实墙钟回拨与乱序样本
        let monotonicTime: TimeInterval?

        init(
            date: Date,
            trustedSystemLoad: Double?,
            batteryChannel: BatteryChannel,
            temperatureCelsius: Double?,
            expectedInterval: TimeInterval,
            monotonicTime: TimeInterval? = nil
        ) {
            self.date = date
            self.trustedSystemLoad = trustedSystemLoad
            self.batteryChannel = batteryChannel
            self.temperatureCelsius = temperatureCelsius
            self.expectedInterval = expectedInterval
            self.monotonicTime = monotonicTime
        }
    }

    /// 单个连续量的零阶保持状态。样本有效期 = 取样时刻 + 保持上限；
    /// attributedTo 记录已并入窗口累计的时间推进位置。
    private struct HoldStream {
        var value: Double?
        var validFrom: Date
        var validUntil: Date
        var attributedTo: Date

        static let empty = HoldStream(value: nil, validFrom: .distantPast, validUntil: .distantPast, attributedTo: .distantPast)
    }

    private var windowStart: Date?
    private var systemStream = HoldStream.empty
    private var chargeStream = HoldStream.empty
    private var dischargeStream = HoldStream.empty
    private var temperatureStream = HoldStream.empty

    private var systemSeconds: TimeInterval = 0
    private var systemEnergyWh: Double = 0
    private var systemPeak: Double = 0
    private var chargeWh: Double = 0
    private var chargeSeconds: TimeInterval = 0
    private var dischargeWh: Double = 0
    private var dischargeSeconds: TimeInterval = 0
    private var temperatureSeconds: TimeInterval = 0
    private var temperatureWeightedSum: Double = 0
    private var temperatureMax: Double?

    /// 全局墙钟游标（无单调时钟证实回拨时，早于它的乱序事件一律拒绝）
    private(set) var timelineCursor: Date?
    /// 最近一次被接纳事件对应的单调时钟
    private var lastMonotonicTime: TimeInterval?
    private static let clockJumpThreshold: TimeInterval = 30
    /// 最近完成的分钟窗口队列（有界 ≤16 分钟）：防止定时抖动跨越两个分钟边界时覆写丢失上一完整分钟。
    private var completedAggregates: [MinuteAggregate] = []
    private static let completedQueueLimit = 16
    var lastCompleted: MinuteAggregate? { completedAggregates.last }

    /// 记录一次成功基础读取。
    mutating func observe(_ observation: Observation) {
        guard observation.date.timeIntervalSince1970.isFinite,
              observation.expectedInterval.isFinite,
              observation.expectedInterval > 0
        else { return }
        let mono = validMonotonic(observation.monotonicTime)
        if let mono, let prevMono = lastMonotonicTime, mono < prevMono {
            return
        }

        if let cursor = timelineCursor {
            let wallDelta = observation.date.timeIntervalSince(cursor)
            if wallDelta < 0 {
                // 仅在单调时钟证实时间确实向前推进时认定为系统墙钟回拨；否则按乱序拒绝。
                guard let mono, let prevMono = lastMonotonicTime, mono >= prevMono else { return }
                clearHoldStreams()
                if windowStart != nil {
                    finalizeCurrentWindow()
                }
                beginWindow(at: Self.floorToWindow(observation.date))
                install(observation, at: observation.date)
                timelineCursor = observation.date
                lastMonotonicTime = mono
                return
            }
            if let mono, let prevMono = lastMonotonicTime,
               abs(wallDelta - (mono - prevMono)) > Self.clockJumpThreshold {
                // 墙钟大幅前跳（如 NTP 校时或未捕获休眠）：先清空保持链，严禁跨跳变伪造积分。
                clearHoldStreams()
                let targetStart = Self.floorToWindow(observation.date)
                if windowStart != targetStart {
                    if windowStart != nil {
                        finalizeCurrentWindow()
                    }
                    beginWindow(at: targetStart)
                }
                install(observation, at: observation.date)
                timelineCursor = observation.date
                lastMonotonicTime = mono
                return
            }
        }

        advanceWindows(through: observation.date)
        integrateContinuous(until: observation.date)
        install(observation, at: observation.date)
        timelineCursor = observation.date
        if let mono { lastMonotonicTime = mono }
    }

    /// 睡眠开始：立即截断全部连续量（保持链清空），防止睡眠前功率延伸进睡眠窗口。
    mutating func truncateContinuity(at date: Date, monotonicTime: TimeInterval? = nil) {
        guard date.timeIntervalSince1970.isFinite else { return }
        let mono = validMonotonic(monotonicTime)
        if let mono, let prevMono = lastMonotonicTime, mono < prevMono {
            return
        }
        if let cursor = timelineCursor {
            let wallDelta = date.timeIntervalSince(cursor)
            if wallDelta < 0 {
                guard let mono, let prevMono = lastMonotonicTime, mono >= prevMono else { return }
                clearHoldStreams()
                if windowStart != nil {
                    finalizeCurrentWindow()
                }
                timelineCursor = date
                lastMonotonicTime = mono
                return
            }
            if let mono, let prevMono = lastMonotonicTime,
               abs(wallDelta - (mono - prevMono)) > Self.clockJumpThreshold {
                clearHoldStreams()
                if windowStart != nil, Self.floorToWindow(date) != windowStart {
                    finalizeCurrentWindow()
                }
                timelineCursor = date
                lastMonotonicTime = mono
                return
            }
        }
        advanceWindows(through: date)
        integrateContinuous(until: date)
        clearHoldStreams()
        timelineCursor = date
        if let mono { lastMonotonicTime = mono }
    }

    private func validMonotonic(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private mutating func clearHoldStreams() {
        systemStream.value = nil
        chargeStream.value = nil
        dischargeStream.value = nil
        temperatureStream.value = nil
    }

    /// 取走全部待提交的已完成窗口聚合（按时间升序）并清空队列。
    mutating func takeCompletedAggregates() -> [MinuteAggregate] {
        defer { completedAggregates.removeAll(keepingCapacity: true) }
        return completedAggregates
    }

    /// 兼容接口：取走最近完成的单个窗口聚合并清空队列。
    mutating func takeCompletedAggregate() -> MinuteAggregate? {
        takeCompletedAggregates().last
    }

    // MARK: - 保持上限

    /// 单个连续样本的保持上限：min(30 秒, 2×预期间隔)。
    static func holdLimit(forExpectedInterval interval: TimeInterval) -> TimeInterval {
        min(maximumHold, 2 * interval)
    }

    static func floorToWindow(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 / windowLength).rounded(.down) * windowLength)
    }

    // MARK: - 内部积分

    private static func consume(
        _ stream: inout HoldStream,
        until end: Date,
        windowStart: Date?
    ) -> (value: Double, seconds: TimeInterval)? {
        guard let value = stream.value else { return nil }
        let upper = min(end, stream.validUntil)
        let lower = max(stream.attributedTo, stream.validFrom, windowStart ?? .distantPast)
        defer {
            stream.attributedTo = max(stream.attributedTo, upper)
            if end >= stream.validUntil { stream.value = nil }
        }
        guard upper > lower else { return nil }
        return (value, upper.timeIntervalSince(lower))
    }

    private mutating func integrateContinuous(until end: Date) {
        let start = windowStart ?? .distantPast
        if let s = Self.consume(&systemStream, until: end, windowStart: start) {
            systemSeconds += s.seconds
            systemEnergyWh += s.value * s.seconds / 3600
            systemPeak = max(systemPeak, s.value)
        }
        if let s = Self.consume(&chargeStream, until: end, windowStart: start) {
            chargeSeconds += s.seconds
            chargeWh += s.value * s.seconds / 3600
        }
        if let s = Self.consume(&dischargeStream, until: end, windowStart: start) {
            dischargeSeconds += s.seconds
            dischargeWh += s.value * s.seconds / 3600
        }
        if let s = Self.consume(&temperatureStream, until: end, windowStart: start) {
            temperatureSeconds += s.seconds
            temperatureWeightedSum += s.value * s.seconds
            temperatureMax = max(temperatureMax ?? s.value, s.value)
        }
    }

    private mutating func install(_ observation: Observation, at date: Date) {
        let expiry = date.addingTimeInterval(Self.holdLimit(forExpectedInterval: observation.expectedInterval))
        let sanitizedSystem = observation.trustedSystemLoad.flatMap { ($0.isFinite && $0 >= 0 && $0 < 500) ? $0 : nil }
        systemStream = HoldStream(
            value: sanitizedSystem,
            validFrom: date, validUntil: expiry, attributedTo: date
        )
        switch observation.batteryChannel {
        case .charge(let watts) where watts.isFinite && watts >= 0 && watts < 500:
            chargeStream = HoldStream(value: watts, validFrom: date, validUntil: expiry, attributedTo: date)
            dischargeStream = HoldStream.empty
        case .discharge(let watts) where watts.isFinite && watts >= 0 && watts < 500:
            chargeStream = HoldStream.empty
            dischargeStream = HoldStream(value: watts, validFrom: date, validUntil: expiry, attributedTo: date)
        case .charge, .discharge, .unknown:
            chargeStream = HoldStream.empty
            dischargeStream = HoldStream.empty
        }
        let sanitizedTemp = observation.temperatureCelsius.flatMap {
            ($0.isFinite && (-20...100).contains($0)) ? $0 : nil
        }
        temperatureStream = HoldStream(
            value: sanitizedTemp,
            validFrom: date, validUntil: expiry, attributedTo: date
        )
    }

    /// 跨越窗口边界时收尾当前窗口；中间完全缺失的分钟不生成空窗口。
    private mutating func advanceWindows(through date: Date) {
        if let start = windowStart, date < start.addingTimeInterval(Self.windowLength) { return }
        let targetStart = Self.floorToWindow(date)
        if windowStart != nil {
            finalizeCurrentWindow()
        }
        beginWindow(at: targetStart)
    }

    private mutating func beginWindow(at start: Date) {
        windowStart = start
        systemSeconds = 0
        systemEnergyWh = 0
        systemPeak = 0
        chargeWh = 0
        chargeSeconds = 0
        dischargeWh = 0
        dischargeSeconds = 0
        temperatureSeconds = 0
        temperatureWeightedSum = 0
        temperatureMax = nil
    }

    private mutating func finalizeCurrentWindow() {
        guard let start = windowStart else { return }
        let end = start.addingTimeInterval(Self.windowLength)

        // 未过期样本的尾巴按窗口末端入账，剩余有效期延续到下一窗口
        integrateContinuous(until: end)

        let duration = Self.windowLength
        let finished = MinuteAggregate(
            windowStart: start,
            systemEnergyWh: systemSeconds > 0 ? systemEnergyWh : nil,
            systemPowerAverage: systemSeconds > 0 ? systemEnergyWh * 3600 / systemSeconds : nil,
            systemPowerPeak: systemSeconds > 0 ? systemPeak : nil,
            systemCoverage: clamp01(systemSeconds / duration),
            batteryChargeSeconds: chargeSeconds,
            batteryDischargeWh: dischargeWh,
            batteryDischargeSeconds: dischargeSeconds,
            temperatureAverage: temperatureSeconds > 0 ? temperatureWeightedSum / temperatureSeconds : nil,
            temperatureMaximum: temperatureMax,
            temperatureCoverage: clamp01(temperatureSeconds / duration),
            batteryChargeWh: chargeWh
        )
        completedAggregates.append(finished)
        if completedAggregates.count > Self.completedQueueLimit {
            completedAggregates.removeFirst(completedAggregates.count - Self.completedQueueLimit)
        }
        windowStart = nil
    }

    private func clamp01(_ value: Double) -> Double {
        min(1, max(0, value))
    }
}
