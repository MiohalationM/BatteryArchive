import Foundation

/// Calendar days remain consecutive after recording starts, including later gaps.
struct UsageDateWindow {
    let firstDay: Date
    let today: Date
    let selectedDay: Date
    let days: [Date]
    let pageIndex: Int
    let lastPageIndex: Int

    init(firstRecordedAt: Date?, selectedDate: Date, now: Date, calendar: Calendar, retentionDays: Int? = 30) {
        today = calendar.startOfDay(for: now)
        let dayNow = today
        let retainedStart = retentionDays.map {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: -max(0, $0 - 1), to: dayNow)!)
        } ?? .distantPast
        firstDay = min(today, max(retainedStart, calendar.startOfDay(for: firstRecordedAt ?? now)))
        selectedDay = min(today, max(firstDay, calendar.startOfDay(for: selectedDate)))
        let count = calendar.dateComponents([.day], from: firstDay, to: today).day ?? 0
        lastPageIndex = count / 7
        pageIndex = (calendar.dateComponents([.day], from: firstDay, to: selectedDay).day ?? 0) / 7
        let anchor = firstDay
        days = (pageIndex * 7...min(count, pageIndex * 7 + 6)).map {
            calendar.startOfDay(for: calendar.date(byAdding: .day, value: $0, to: anchor)!)
        }
    }
}

struct UsageSessionSummary: Equatable, Sendable, Identifiable {
    var id: String
    var start: Date
    var end: Date
    var screenOnSeconds: TimeInterval = 0
    var screenOffSeconds: TimeInterval = 0
    var dischargeWh: Double = 0
    var powerSeconds: TimeInterval = 0
    var estimatedSeconds: TimeInterval = 0
    var startLevel: Double?
    var endLevel: Double?
    var ongoing = false
    /// 起点未亲眼观测到拔电（如应用启动已在离电、唤醒或前序缺口截断）
    var startIncomplete = false
    /// 已结束时段未亲眼观测到插电（如因休眠、缺口、读取失败或退出截断）
    var endIncomplete = false
    var detailsTruncated = false
    var duration: TimeInterval { end.timeIntervalSince(start) }
    var coverage: Double { duration > 0 ? min(1, powerSeconds / duration) : 0 }
}

struct UsagePlotPoint: Equatable, Sendable, Identifiable {
    var date: Date
    var level: Double
    var segment: Int
    var id: String { "\(segment):\(date.timeIntervalSince1970)" }
}

struct UsageDayReview: Equatable, Sendable, Identifiable {
    var date: Date
    var end: Date
    var elapsedSeconds: TimeInterval
    var screenOnSeconds: TimeInterval = 0
    var screenOffSeconds: TimeInterval = 0
    var onPowerSeconds: TimeInterval = 0
    var sleepSeconds: TimeInterval = 0
    var dischargeWh: Double = 0
    var powerSeconds: TimeInterval = 0
    var estimatedSeconds: TimeInterval = 0
    var readFailureSeconds: TimeInterval = 0
    var samplingGapSeconds: TimeInterval = 0
    var clockRollbackCount = 0
    var skippedLines = 0
    var hasDetailedRecords = true
    var levels: [UsagePlotPoint] = []
    var spans: [UsageSpan] = []
    var sessions: [UsageSessionSummary] = []
    var detailsTruncated = false
    var id: Date { date }
    var batterySeconds: TimeInterval { screenOnSeconds + screenOffSeconds }
    var knownSeconds: TimeInterval { batterySeconds + onPowerSeconds + sleepSeconds }
    var unknownSeconds: TimeInterval { max(0, elapsedSeconds - knownSeconds) }
    /// 应用未运行或未归类的未记录时长
    var unrecordedSeconds: TimeInterval { max(0, unknownSeconds - readFailureSeconds - samplingGapSeconds) }
    var hasEvidence: Bool { knownSeconds > 0 }
    var powerCoverage: Double? { batterySeconds > 0 ? min(1, powerSeconds / batterySeconds) : nil }
    var canRankSessions: Bool {
        let finished = sessions.filter { !$0.ongoing }
        return !finished.isEmpty && finished.allSatisfy {
            $0.coverage >= 0.9 && !$0.detailsTruncated && !$0.startIncomplete && !$0.endIncomplete
        }
    }
    var displaySessions: [UsageSessionSummary] {
        let ongoing = sessions.filter(\.ongoing)
        let finished = sessions.filter { !$0.ongoing }
        return ongoing + (canRankSessions
            ? finished.sorted { $0.dischargeWh > $1.dischargeWh }
            : finished.sorted { $0.start > $1.start })
    }

    mutating func apply(_ summaries: [UsageDailySummary]) {
        guard !summaries.isEmpty else { return }
        onPowerSeconds = summaries.reduce(0) { $0 + $1.onPowerSeconds }
        screenOnSeconds = summaries.reduce(0) { $0 + $1.screenOnSeconds }
        screenOffSeconds = summaries.reduce(0) { $0 + $1.screenOffSeconds }
        sleepSeconds = summaries.reduce(0) { $0 + $1.sleepSeconds }
        dischargeWh = summaries.reduce(0) { $0 + $1.dischargeWh }
        powerSeconds = summaries.reduce(0) { $0 + $1.powerSeconds }
        estimatedSeconds = summaries.reduce(0) { $0 + $1.estimatedSeconds }
    }
}

enum UsageHistoryAnalysis {
    static func reviews(
        stored: [UsageBucket], live: [UsageBucket], dates: [Date], calendar: Calendar, now: Date
    ) -> [UsageDayReview] {
        var byID: [String: UsageBucket] = [:]
        for bucket in stored + live {
            var validated = bucket
            validated.isLive = false
            guard validated.isValid, bucket.timeZoneID == calendar.timeZone.identifier,
                  bucket.end <= now.addingTimeInterval(1) else { continue }
            if let old = byID[bucket.id], old.end > bucket.end { continue }
            byID[bucket.id] = bucket
        }
        let ordered = byID.values.sorted { lhs, rhs in
            if lhs.start != rhs.start { return lhs.start < rhs.start }
            if lhs.end != rhs.end { return lhs.end > rhs.end }
            if lhs.isLive != rhs.isLive { return lhs.isLive }
            return lhs.id < rhs.id
        }
        // Inputs may contain a live bucket also present in the journal or an
        // overlapping run. Keep each wall-clock interval at most once.
        var lastEnd = Date.distantPast
        let unique = ordered.filter { bucket in
            guard bucket.start >= lastEnd else { return false }
            lastEnd = bucket.end
            return true
        }
        return dates.map { date in
            let start = calendar.startOfDay(for: date)
            let end = calendar.dateInterval(of: .day, for: start)?.end
                ?? calendar.date(byAdding: .day, value: 1, to: start)!
            let elapsed = max(0, min(now, end).timeIntervalSince(start))
            var review = UsageDayReview(date: start, end: end, elapsedSeconds: elapsed)
            let buckets = unique.filter { $0.start >= start && $0.end <= end && $0.end > start }
            for bucket in buckets {
                review.screenOnSeconds += bucket.screenOnSeconds
                review.screenOffSeconds += bucket.screenOffSeconds
                review.onPowerSeconds += bucket.onPowerSeconds
                review.sleepSeconds += bucket.sleepSeconds
                review.dischargeWh += bucket.dischargeWh
                review.powerSeconds += bucket.powerSeconds
                review.estimatedSeconds += bucket.estimatedSeconds
                review.readFailureSeconds += bucket.readFailureSeconds ?? 0
                review.samplingGapSeconds += bucket.samplingGapSeconds ?? 0
                review.clockRollbackCount += bucket.clockRollbackCount ?? 0
                review.detailsTruncated = review.detailsTruncated || bucket.detailsTruncated
            }
            review.spans = mergedSpans(buckets.flatMap(\.spans))
            let levels = uniqueLevels(buckets.flatMap(\.levels))
            review.levels = plotPoints(levels)
            review.sessions = sessions(in: review.spans, levels: levels, buckets: buckets, now: now)
            return review
        }
    }

    private static func uniqueLevels(_ input: [UsageLevelPoint]) -> [UsageLevelPoint] {
        var byDate: [Date: UsageLevelPoint] = [:]
        for point in input { byDate[point.date] = point }
        return byDate.values.sorted { $0.date < $1.date }
    }

    private static func plotPoints(_ input: [UsageLevelPoint]) -> [UsagePlotPoint] {
        let trend = input.enumerated().map { index, point in
            TrendPoint(time: point.date, value: point.level,
                       breakBefore: index > 0 && input[index - 1].continuityID != point.continuityID)
        }
        var segment = 0
        return ChartDownsampler.downsampleTrendPoints(trend, maxPoints: 240).map { point in
            if point.breakBefore { segment += 1 }
            return UsagePlotPoint(date: point.time, level: point.value, segment: segment)
        }
    }

    private static func mergedSpans(_ input: [UsageSpan]) -> [UsageSpan] {
        var result: [UsageSpan] = []
        for span in input.sorted(by: { $0.start < $1.start }) {
            if let last = result.last, last.end == span.start,
               last.activity == span.activity, last.continuityID == span.continuityID,
               last.sessionID == span.sessionID {
                let index = result.count - 1
                result[index].end = span.end
                result[index].dischargeWh += span.dischargeWh
                result[index].powerSeconds += span.powerSeconds
                result[index].estimatedSeconds += span.estimatedSeconds
                result[index].endObserved = span.endObserved
            } else {
                result.append(span)
            }
        }
        return result
    }

    private static func sessions(
        in spans: [UsageSpan], levels: [UsageLevelPoint], buckets: [UsageBucket], now: Date
    ) -> [UsageSessionSummary] {
        var result: [UsageSessionSummary] = []
        var firstStartObserved: [Bool?] = []
        var lastEndObserved: [Bool?] = []
        var lastSessionID: UUID?
        for span in spans {
            guard span.activity.isOnBattery, let sessionID = span.sessionID else {
                lastSessionID = nil
                continue
            }
            if result.last?.end != span.start || lastSessionID != sessionID {
                result.append(UsageSessionSummary(
                    id: "\(sessionID.uuidString):\(span.start.timeIntervalSince1970)",
                    start: span.start, end: span.start
                ))
                firstStartObserved.append(span.startObserved)
                lastEndObserved.append(span.endObserved)
            }
            let index = result.count - 1
            result[index].end = span.end
            if span.activity == .batteryScreenOn { result[index].screenOnSeconds += span.duration }
            else { result[index].screenOffSeconds += span.duration }
            result[index].dischargeWh += span.dischargeWh
            result[index].powerSeconds += span.powerSeconds
            result[index].estimatedSeconds += span.estimatedSeconds
            lastEndObserved[index] = span.endObserved
            lastSessionID = sessionID
        }
        for index in result.indices {
            var summary = result[index]
            let matching = levels.filter { $0.date >= summary.start && $0.date <= summary.end }
            summary.startLevel = matching.first?.level
            summary.endLevel = matching.last?.level
            summary.detailsTruncated = buckets.contains {
                $0.detailsTruncated && $0.start < summary.end && $0.end > summary.start
            }
            summary.ongoing = buckets.contains { bucket in
                bucket.isLive && bucket.end >= now.addingTimeInterval(-1)
                    && bucket.spans.last?.sessionID == lastID(for: summary, spans: spans)
                    && bucket.spans.last?.activity.isOnBattery == true
                    && summary.end == bucket.end
            }
            // 旧记录（nil）不误标；新记录仅在明确未观测到拔电/插电边界时标注不完整。
            summary.startIncomplete = (firstStartObserved[index] == false)
            summary.endIncomplete = (!summary.ongoing && lastEndObserved[index] == false)
            result[index] = summary
        }
        return result
    }

    private static func lastID(for session: UsageSessionSummary, spans: [UsageSpan]) -> UUID? {
        spans.last(where: { $0.end == session.end && $0.activity.isOnBattery })?.sessionID
    }
}
