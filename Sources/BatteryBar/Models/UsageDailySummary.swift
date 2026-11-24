import Foundation

/// Permanent, small daily totals; never contains the detailed chart samples.
struct UsageDailySummary: Codable, Equatable, Sendable, Identifiable {
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
    var id: String { "\(measurementEpoch)|\(timeZoneID)|\(date.timeIntervalSince1970)" }

    init(bucket: UsageBucket) {
        measurementEpoch = bucket.measurementEpoch
        timeZoneID = bucket.timeZoneID
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: bucket.timeZoneID)!
        date = calendar.startOfDay(for: bucket.start)
        firstRecord = bucket.start
        appliedThrough = bucket.start
    }

    mutating func include(_ bucket: UsageBucket) {
        var checked = bucket
        checked.isLive = false
        guard checked.isValid, bucket.measurementEpoch == measurementEpoch,
              bucket.timeZoneID == timeZoneID, bucket.start >= appliedThrough else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: timeZoneID)!
        let dayEnd = calendar.dateInterval(of: .day, for: date)?.end
            ?? calendar.date(byAdding: .day, value: 1, to: date)!
        guard calendar.startOfDay(for: bucket.start) == date,
              bucket.end <= dayEnd else { return }
        firstRecord = min(firstRecord, bucket.start)
        appliedThrough = bucket.end
        onPowerSeconds += bucket.onPowerSeconds
        screenOnSeconds += bucket.screenOnSeconds
        screenOffSeconds += bucket.screenOffSeconds
        sleepSeconds += bucket.sleepSeconds
        dischargeWh += bucket.dischargeWh
        powerSeconds += bucket.powerSeconds
        estimatedSeconds += bucket.estimatedSeconds
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
            let previousAppliedThrough = summary.appliedThrough
            summary.include(bucket)
            if summary.appliedThrough != previousAppliedThrough {
                byID[summary.id] = summary
            }
        }
        return byID.values.sorted { $0.date < $1.date }
    }
}
