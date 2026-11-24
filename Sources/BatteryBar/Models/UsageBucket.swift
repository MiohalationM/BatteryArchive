import Foundation

enum UsageActivity: String, Codable, Sendable {
    case onPower, batteryScreenOn, batteryScreenOff, sleep, unknown

    var isOnBattery: Bool { self == .batteryScreenOn || self == .batteryScreenOff }
}

struct UsageLevelPoint: Codable, Equatable, Sendable, Identifiable {
    var date: Date
    var level: Double
    var continuityID: UUID
    var id: String { "\(continuityID.uuidString):\(date.timeIntervalSince1970)" }
}

struct UsageSpan: Codable, Equatable, Sendable, Identifiable {
    var start: Date
    var end: Date
    var activity: UsageActivity
    var sessionID: UUID?
    var continuityID: UUID
    var dischargeWh: Double = 0
    var powerSeconds: TimeInterval = 0
    var estimatedSeconds: TimeInterval = 0
    /// 离电时段是否真实观察到「接电→离电」拔电起点（nil = 旧版记录未知；false = 启动/唤醒/缺口截断）。
    var startObserved: Bool?
    /// 离电时段是否真实观察到「离电→接电」插电终点（nil = 旧版记录未知；false = 睡眠/缺口/退出截断或尚未结束）。
    var endObserved: Bool?
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var id: String { "\(continuityID.uuidString):\(start.timeIntervalSince1970):\(activity.rawValue)" }
}

/// Local-only usage facts.
struct UsageBucket: Codable, Equatable, Sendable, Identifiable {
    var schemaVersion = 1
    var id = UUID().uuidString
    var measurementEpoch: UUID
    var runID: UUID
    var timeZoneID: String
    var start: Date
    var end: Date
    var onPowerSeconds: TimeInterval = 0
    var screenOnSeconds: TimeInterval = 0
    var screenOffSeconds: TimeInterval = 0
    var sleepSeconds: TimeInterval = 0
    var unknownSeconds: TimeInterval = 0
    var dischargeWh: Double = 0
    var powerSeconds: TimeInterval = 0
    var estimatedSeconds: TimeInterval = 0
    /// 缺口原因细分（全部可选，旧版 30 天桶缺键自动解为 nil）：
    /// - `readFailureSeconds`：硬件/系统读取失败或来源矛盾导致的未知时长；
    /// - `samplingGapSeconds`：超过保持上限 `min(30s, 2×预期间隔)` 未收到新样本的采样超时缺口；
    /// - `clockRollbackCount`：休眠唤醒检测到墙钟回拨的次数。
    var readFailureSeconds: TimeInterval?
    var samplingGapSeconds: TimeInterval?
    var clockRollbackCount: Int?
    var spans: [UsageSpan] = []
    var levels: [UsageLevelPoint] = []
    var detailsTruncated = false
    /// A live preview may project a held observation. It is never persisted.
    var isLive = false

    var batterySeconds: TimeInterval { screenOnSeconds + screenOffSeconds }
    var knownSeconds: TimeInterval { onPowerSeconds + batterySeconds + sleepSeconds }
    var duration: TimeInterval { end.timeIntervalSince(start) }

    var isValid: Bool {
        let values = [onPowerSeconds, screenOnSeconds, screenOffSeconds, sleepSeconds,
                      unknownSeconds, dischargeWh, powerSeconds, estimatedSeconds]
        let gapSum = (readFailureSeconds ?? 0) + (samplingGapSeconds ?? 0)
        guard schemaVersion == 1, !isLive,
              start.timeIntervalSince1970.isFinite, end.timeIntervalSince1970.isFinite,
              duration > 0, duration <= 300.001, TimeZone(identifier: timeZoneID) != nil,
              values.allSatisfy({ $0.isFinite && $0 >= 0 }),
              (readFailureSeconds ?? 0).isFinite, (readFailureSeconds ?? 0) >= 0,
              (samplingGapSeconds ?? 0).isFinite, (samplingGapSeconds ?? 0) >= 0,
              gapSum <= unknownSeconds + 0.01,
              (clockRollbackCount ?? 0) >= 0,
              abs(knownSeconds + unknownSeconds - duration) < 0.01,
              powerSeconds <= batterySeconds + 0.001,
              estimatedSeconds <= powerSeconds + 0.001,
              dischargeWh <= powerSeconds * 500 / 3600 + 0.001,
              spans.count <= 64, levels.count <= 64 else { return false }
        let orderedSpans = spans.sorted { $0.start < $1.start }
        let spansNonOverlapping = zip(orderedSpans, orderedSpans.dropFirst()).allSatisfy { $0.end <= $1.start }
        guard spansNonOverlapping else { return false }
        return spans.allSatisfy {
            $0.start >= start && $0.end <= end && $0.duration > 0
                && $0.dischargeWh.isFinite && $0.dischargeWh >= 0
                && $0.powerSeconds.isFinite && $0.powerSeconds >= 0
                && $0.powerSeconds <= $0.duration + 0.001
                && $0.estimatedSeconds.isFinite && $0.estimatedSeconds >= 0
                && $0.estimatedSeconds <= $0.powerSeconds + 0.001
                && ($0.activity.isOnBattery || ($0.dischargeWh == 0 && $0.powerSeconds == 0))
        } && levels.allSatisfy {
            $0.date >= start && $0.date <= end && $0.level.isFinite && (0...100).contains($0.level)
        }
    }
}

struct UsageHistoryPage: Sendable {
    var buckets: [UsageBucket] = []
    var availableTimeZones: [String] = []
    var error: String?
    var skippedLines = 0
}
