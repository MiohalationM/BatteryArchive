import Foundation
import Observation

enum UsageReportQuery {
    static func day(
        _ date: Date,
        summaries: [UsageDailySummary],
        buckets: [UsageBucket],
        live: [UsageBucket],
        calendar: Calendar,
        now: Date,
        skippedLines: Int = 0
    ) -> UsageDayReview {
        var result = UsageHistoryAnalysis.reviews(stored: buckets, live: live, dates: [date],
                                                 calendar: calendar, now: now)[0]
        let day = result.date
        let matching = summaries.filter { $0.date == day && $0.timeZoneID == calendar.timeZone.identifier }
        result.apply(matching)
        result.skippedLines = skippedLines
        let withinRetention = result.end > now.addingTimeInterval(-UsageHistoryStore.retention)
        let isPastDay = result.end <= now
        let hasBucketDetail = !result.spans.isEmpty || !result.levels.isEmpty
        // 若超过 30 天保留期，或虽在 30 天内但因 10,000 桶硬上限被提前裁剪（历史日有汇总却无任何明细桶），均明确标记无明细曲线。
        result.hasDetailedRecords = withinRetention && !(isPastDay && result.hasEvidence && !hasBucketDetail)
        return result
    }
}

/// One published snapshot for overview, menu and history. No extra sampling timer.
@MainActor @Observable final class UsageReportModel {
    @ObservationIgnored private var followsSystemTimeZone = true
    var timeZoneID = TimeZone.current.identifier {
        didSet {
            guard timeZoneID != oldValue else { return }
            followsSystemTimeZone = (timeZoneID == TimeZone.autoupdatingCurrent.identifier)
            generation += 1
            publishedTimeZoneID = nil
            summaries = []
            today = nil
            cachedTodayBatterySeconds = nil
            cachedTodayDate = nil
            live = []
            error = nil
            revision &+= 1
        }
    }

    func syncSystemTimeZoneIfFollowing() {
        guard followsSystemTimeZone else { return }
        let systemID = TimeZone.autoupdatingCurrent.identifier
        if timeZoneID != systemID {
            timeZoneID = systemID
        }
    }
    private(set) var summaries: [UsageDailySummary] = []
    private(set) var today: UsageDayReview?
    private(set) var cachedTodayBatterySeconds: TimeInterval? = nil
    private(set) var timeZones: [String] = []
    private(set) var error: String?
    private(set) var revision = 0
    @ObservationIgnored private var cachedTodayDate: Date?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var live: [UsageBucket] = []
    @ObservationIgnored private var publishedTimeZoneID: String?
    @ObservationIgnored private let loadSummaries: @Sendable () async -> [UsageDailySummary]
    @ObservationIgnored private let loadHistory: @Sendable (DateInterval, Date) async -> UsageHistoryPage

    /// 供菜单栏弹窗首帧展示今日离电时长；详细缓存释放后仍保留轻量化数值，避免重开弹窗闪烁 `"—"`。
    var displayTodayBatterySeconds: TimeInterval? {
        today?.hasEvidence == true ? today?.batterySeconds : cachedTodayBatterySeconds
    }

    /// Loaders keep tests isolated; production reads remain on the utility task.
    init(loadSummaries: @escaping @Sendable () async -> [UsageDailySummary] = {
        DataStore.shared.usageDailySummaries()
    }, loadHistory: @escaping @Sendable (DateInterval, Date) async -> UsageHistoryPage = {
        DataStore.shared.usageHistory(in: $0, now: $1)
    }) {
        self.loadSummaries = loadSummaries
        self.loadHistory = loadHistory
    }

    var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return value
    }
    var firstRecord: Date { summaries.map(\.firstRecord).min() ?? Date() }

    /// 全部 UI 关闭进入后台闲置时释放详细汇总/明细缓存并取消在途刷新，同时保留轻量化 `cachedTodayBatterySeconds`。
    func releaseDetailedCache() {
        generation += 1
        today = nil
        live = []
        summaries = []
        publishedTimeZoneID = nil
    }

    func refresh(live: [UsageBucket], now: Date = Date()) async {
        generation += 1
        let token = generation, calendar = calendar, zone = timeZoneID
        let start = calendar.startOfDay(for: now)
        let end = calendar.dateInterval(of: .day, for: start)?.end
            ?? calendar.date(byAdding: .day, value: 1, to: start)!
        if today?.date != start { today = nil }
        if let cachedDate = cachedTodayDate, cachedDate != start {
            cachedTodayBatterySeconds = nil
            cachedTodayDate = nil
        }
        let loadSummaries = loadSummaries, loadHistory = loadHistory
        let result = await Task.detached(priority: .utility) {
            let stored = await loadSummaries()
            let summaries = UsageDailySummary.merging(stored, live: live, zone: zone)
            let page = await loadHistory(DateInterval(start: start, end: end), now)
            let today = UsageReportQuery.day(
                start, summaries: summaries, buckets: page.buckets,
                live: live, calendar: calendar, now: now, skippedLines: page.skippedLines
            )
            return (summaries, today, page.error, Array(Set(stored.map(\.timeZoneID) + page.availableTimeZones)).sorted())
        }.value
        guard token == generation, zone == timeZoneID else { return }
        self.live = live
        publishedTimeZoneID = zone
        summaries = result.0
        today = result.1
        if result.1.hasEvidence {
            cachedTodayBatterySeconds = result.1.batterySeconds
            cachedTodayDate = result.1.date
        } else {
            cachedTodayBatterySeconds = nil
            cachedTodayDate = result.1.date
        }
        error = result.2
        timeZones = result.3
        revision &+= 1
    }

    func detail(for date: Date, now: Date = Date()) async -> UsageDayReview {
        let calendar = calendar
        let start = calendar.startOfDay(for: date)
        if calendar.isDate(date, inSameDayAs: now), let today,
           today.date == start, publishedTimeZoneID == timeZoneID { return today }
        let summaries = summaries, live = live
        let end = calendar.dateInterval(of: .day, for: start)?.end
            ?? calendar.date(byAdding: .day, value: 1, to: start)!
        let loadHistory = loadHistory
        return await Task.detached(priority: .utility) {
            let page = await loadHistory(DateInterval(start: start, end: end), now)
            return UsageReportQuery.day(
                date, summaries: summaries, buckets: page.buckets,
                live: live, calendar: calendar, now: now, skippedLines: page.skippedLines
            )
        }.value
    }
}
