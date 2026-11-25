import Foundation

/// Permanent, small daily totals; never contains the detailed chart samples.
struct UsageDailySummary: Codable, Equatable, Sendable, Identifiable {
    struct CoveredInterval: Codable, Equatable, Sendable {
        var start: Date
        var end: Date
    }

    var version = 1
    var measurementEpoch: UUID
    var timeZoneID: String
    var date: Date
    var firstRecord: Date
    var appliedThrough: Date
    var onPowerSeconds: Double = 0
    var screenOnSeconds: Double = 0
    var screenOffSeconds: Double = 0
    var sleepSeconds: Double = 0
    var dischargeWh: Double = 0
    var powerSeconds: Double = 0
    var estimatedSeconds: Double = 0
    /// 已计入该日汇总的有序不重叠区间；旧版 JSON 缺键解码为 nil，回退为 `[firstRecord, appliedThrough)`。
    var coveredIntervals: [CoveredInterval]?
    var id: String { "\(measurementEpoch)|\(timeZoneID)|\(date.timeIntervalSince1970)" }

    var effectiveCoveredIntervals: [CoveredInterval] {
        if let coveredIntervals { return coveredIntervals }
        return appliedThrough > firstRecord
            ? [CoveredInterval(start: firstRecord, end: appliedThrough)]
            : []
    }

    init(bucket: UsageBucket) {
        measurementEpoch = bucket.measurementEpoch
        timeZoneID = bucket.timeZoneID
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: bucket.timeZoneID)!
        date = calendar.startOfDay(for: bucket.start)
        firstRecord = bucket.start
        appliedThrough = bucket.start
        coveredIntervals = []
    }

    @discardableResult
    mutating func include(_ bucket: UsageBucket) -> Bool {
        var checked = bucket
        checked.isLive = false
        guard checked.isValid, bucket.measurementEpoch == measurementEpoch,
              bucket.timeZoneID == timeZoneID else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        let dayEnd = calendar.dateInterval(of: .day, for: date)?.end
            ?? calendar.date(byAdding: .day, value: 1, to: date)!
        guard calendar.startOfDay(for: bucket.start) == date,
              bucket.end <= dayEnd else { return false }

        var intervals = effectiveCoveredIntervals
        var lo = 0
        var hi = intervals.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if intervals[mid].start < bucket.start {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0, intervals[lo - 1].end > bucket.start { return false }
        if lo < intervals.count, intervals[lo].start < bucket.end { return false }

        let wasEmpty = intervals.isEmpty
        intervals.insert(CoveredInterval(start: bucket.start, end: bucket.end), at: lo)
        if lo + 1 < intervals.count, intervals[lo].end == intervals[lo + 1].start {
            intervals[lo].end = intervals[lo + 1].end
            intervals.remove(at: lo + 1)
        }
        if lo > 0, intervals[lo - 1].end == intervals[lo].start {
            intervals[lo - 1].end = intervals[lo].end
            intervals.remove(at: lo)
        }
        coveredIntervals = intervals
        if wasEmpty {
            firstRecord = bucket.start
            appliedThrough = bucket.end
        } else {
            firstRecord = min(firstRecord, bucket.start)
            appliedThrough = max(appliedThrough, bucket.end)
        }
        onPowerSeconds += bucket.onPowerSeconds
        screenOnSeconds += bucket.screenOnSeconds
        screenOffSeconds += bucket.screenOffSeconds
        sleepSeconds += bucket.sleepSeconds
        dischargeWh += bucket.dischargeWh
        powerSeconds += bucket.powerSeconds
        estimatedSeconds += bucket.estimatedSeconds
        return true
    }

    var isValid: Bool {
        guard version == 1, let zone = TimeZone(identifier: timeZoneID),
              date.timeIntervalSince1970.isFinite,
              firstRecord.timeIntervalSince1970.isFinite,
              appliedThrough.timeIntervalSince1970.isFinite else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let end = calendar.dateInterval(of: .day, for: date)?.end
            ?? calendar.date(byAdding: .day, value: 1, to: date)!
        if let intervals = coveredIntervals {
            guard !intervals.isEmpty else { return false }
            var previousEnd = date
            for interval in intervals {
                guard interval.start.timeIntervalSince1970.isFinite,
                      interval.end.timeIntervalSince1970.isFinite,
                      interval.start < interval.end,
                      interval.start >= previousEnd,
                      interval.end <= end else { return false }
                previousEnd = interval.end
            }
            guard abs(intervals.first!.start.timeIntervalSince(firstRecord)) <= 0.001,
                  abs(intervals.last!.end.timeIntervalSince(appliedThrough)) <= 0.001 else {
                return false
            }
        }
        let values = [onPowerSeconds, screenOnSeconds, screenOffSeconds, sleepSeconds,
                      dischargeWh, powerSeconds, estimatedSeconds]
        return calendar.startOfDay(for: date) == date
            && firstRecord >= date && appliedThrough > firstRecord && appliedThrough <= end
            && values.allSatisfy { $0.isFinite && $0 >= 0 }
            && onPowerSeconds + screenOnSeconds + screenOffSeconds + sleepSeconds <= end.timeIntervalSince(date) + 0.01
            && powerSeconds <= screenOnSeconds + screenOffSeconds + 0.001
            && estimatedSeconds <= powerSeconds + 0.001
            && dischargeWh <= powerSeconds * 500 / 3_600 + 0.001
    }

    static func merging(_ stored: [Self], live: [UsageBucket], zone: String) -> [Self] {
        var byID = Dictionary(stored.filter { $0.timeZoneID == zone }.map { ($0.id, $0) },
                              uniquingKeysWith: { first, _ in first })
        for bucket in live.sorted(by: { $0.start < $1.start }) where bucket.timeZoneID == zone {
            var checked = bucket
            checked.isLive = false
            guard checked.isValid else { continue }
            let seed = UsageDailySummary(bucket: bucket)
            var summary = byID[seed.id] ?? seed
            if summary.include(bucket) {
                byID[summary.id] = summary
            }
        }
        return byID.values.sorted { $0.date < $1.date }
    }
}
