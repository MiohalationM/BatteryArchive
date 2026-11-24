import Foundation
import Testing
@testable import BatteryArchive

@Suite @MainActor struct UsageReportModelTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "GMT")!
        return calendar
    }

    private func date(_ day: Int, hour: Int = 12, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func summary(at start: Date, zone: String = "GMT", onPowerSeconds: Double = 60) -> UsageDailySummary {
        var bucket = UsageBucket(measurementEpoch: UUID(), runID: UUID(), timeZoneID: zone,
                                 start: start, end: start.addingTimeInterval(onPowerSeconds))
        bucket.onPowerSeconds = onPowerSeconds
        var summary = UsageDailySummary(bucket: bucket)
        summary.include(bucket)
        return summary
    }

    @Test func todayCacheIsReusedOnlyWithinItsNaturalDay() async {
        let stored = [summary(at: date(1))]
        let calls = HistoryReadCount()
        let reports = UsageReportModel(loadSummaries: { stored }, loadHistory: { _, _ in
            await calls.record()
            return UsageHistoryPage()
        })
        reports.timeZoneID = "GMT"
        await reports.refresh(live: [], now: date(1, hour: 23, minute: 59))
        let cached = await reports.detail(for: date(1), now: date(1, hour: 23, minute: 59))
        #expect(cached.onPowerSeconds == 60)
        #expect(await calls.count == 1)

        let nextDay = date(2, hour: 0, minute: 1)
        let result = await reports.detail(for: nextDay, now: nextDay)
        #expect(result.date == utc.startOfDay(for: nextDay))
        #expect(result.onPowerSeconds == 0)
        #expect(await calls.count == 2)
    }

    @Test func timeZoneChangeImmediatelyInvalidatesPublishedReports() async {
        let stored = [summary(at: date(1))]
        let reports = UsageReportModel(loadSummaries: { stored }, loadHistory: { _, _ in UsageHistoryPage() })
        reports.timeZoneID = "GMT"
        await reports.refresh(live: [], now: date(1, hour: 15))
        #expect(reports.today?.onPowerSeconds == 60)
        let revision = reports.revision

        reports.timeZoneID = "Asia/Shanghai"
        #expect(reports.today == nil)
        #expect(reports.summaries.isEmpty)
        #expect(reports.revision == revision + 1)
        let interval = reports.calendar.dateInterval(of: .day, for: date(1))!
        let result = await reports.detail(for: date(1), now: date(1, hour: 15))
        #expect(result.date == interval.start)
        #expect(result.onPowerSeconds == 0)
    }

    @Test func timeZoneChangeRejectsAnAlreadyRunningRefreshEvenAfterChangingBack() async {
        let stored = [summary(at: date(1))]
        let gate = PendingSummaryRead()
        let reports = UsageReportModel(loadSummaries: { await gate.read() },
                                       loadHistory: { _, _ in
            UsageHistoryPage(availableTimeZones: ["GMT"], error: "fixture error")
        })
        reports.timeZoneID = "GMT"
        let refresh = Task { await reports.refresh(live: [], now: date(1, hour: 15)) }
        await gate.waitUntilStarted()
        reports.timeZoneID = "Asia/Shanghai"
        reports.timeZoneID = "GMT"
        let revision = reports.revision
        await gate.finish(with: stored)
        await refresh.value
        #expect(reports.today == nil)
        #expect(reports.summaries.isEmpty)
        #expect(reports.error == nil)
        #expect(reports.timeZones.isEmpty)
        #expect(reports.revision == revision)
    }

    @Test func refreshedTimeZoneUsesItsOwnDayAndTotals() async {
        let shanghai = summary(at: date(1), zone: "Asia/Shanghai", onPowerSeconds: 120)
        let stored = [summary(at: date(1)), shanghai]
        let reports = UsageReportModel(loadSummaries: { stored }, loadHistory: { _, _ in UsageHistoryPage() })
        reports.timeZoneID = "GMT"
        await reports.refresh(live: [], now: date(1, hour: 15))
        #expect(reports.today?.onPowerSeconds == 60)

        reports.timeZoneID = "Asia/Shanghai"
        await reports.refresh(live: [], now: date(1, hour: 15))
        let interval = reports.calendar.dateInterval(of: .day, for: date(1))!
        let result = await reports.detail(for: date(1), now: date(1, hour: 15))
        #expect(result.date == interval.start)
        #expect(result.onPowerSeconds == 120)
        #expect(reports.summaries.allSatisfy { $0.timeZoneID == "Asia/Shanghai" })
    }

    @Test func nextDayRefreshClearsYesterdayWhileTheNewReadIsPending() async {
        let stored = [summary(at: date(1))]
        let gate = PendingSummaryRead()
        let reports = UsageReportModel(loadSummaries: { await gate.read() },
                                       loadHistory: { _, _ in UsageHistoryPage() })
        reports.timeZoneID = "GMT"
        let first = Task { await reports.refresh(live: [], now: date(1, hour: 15)) }
        await gate.waitUntilStarted()
        await gate.finish(with: stored)
        await first.value
        #expect(reports.today?.onPowerSeconds == 60)

        await gate.reset()
        let second = Task { await reports.refresh(live: [], now: date(2, hour: 0, minute: 1)) }
        await gate.waitUntilStarted()
        #expect(reports.today == nil)
        await gate.finish(with: stored)
        await second.value
        #expect(reports.today?.date == utc.startOfDay(for: date(2)))
        #expect(reports.today?.onPowerSeconds == 0)
    }

    @Test func releaseDetailedCacheDropsDetailPreservesBatterySecondsAndCancelsInFlightRefresh() async {
        var bucket = UsageBucket(
            measurementEpoch: UUID(),
            runID: UUID(),
            timeZoneID: "GMT",
            start: date(1),
            end: date(1).addingTimeInterval(180)
        )
        bucket.screenOnSeconds = 180
        var batterySummary = UsageDailySummary(bucket: bucket)
        batterySummary.include(bucket)
        let stored = [batterySummary]

        let gate = PendingSummaryRead()
        let reports = UsageReportModel(
            loadSummaries: { await gate.read() },
            loadHistory: { _, _ in UsageHistoryPage() }
        )
        reports.timeZoneID = "GMT"

        let initial = Task { await reports.refresh(live: [], now: date(1, hour: 15)) }
        await gate.waitUntilStarted()
        await gate.finish(with: stored)
        await initial.value
        #expect(reports.today?.batterySeconds == 180)
        #expect(reports.cachedTodayBatterySeconds == 180)
        #expect(reports.displayTodayBatterySeconds == 180)
        #expect(!reports.summaries.isEmpty)

        // Idle teardown drops detailed summaries/today while keeping lightweight Popover metric intact
        reports.releaseDetailedCache()
        #expect(reports.today == nil)
        #expect(reports.summaries.isEmpty)
        #expect(reports.cachedTodayBatterySeconds == 180)
        #expect(reports.displayTodayBatterySeconds == 180)

        // An in-flight refresh invalidated by releaseDetailedCache() must not repopulate after close
        await gate.reset()
        let staleRefresh = Task { await reports.refresh(live: [], now: date(1, hour: 16)) }
        await gate.waitUntilStarted()
        reports.releaseDetailedCache()
        await gate.finish(with: stored)
        await staleRefresh.value
        #expect(reports.today == nil)
        #expect(reports.summaries.isEmpty)
        #expect(reports.displayTodayBatterySeconds == 180)

        // Switching timezone clears cached battery seconds cleanly
        reports.timeZoneID = "Asia/Shanghai"
        #expect(reports.cachedTodayBatterySeconds == nil)
        #expect(reports.displayTodayBatterySeconds == nil)
    }
}

private actor HistoryReadCount {
    private(set) var count = 0
    func record() { count += 1 }
}

/// In-memory loaders keep the report tests independent of DataStore.shared and services.
private actor PendingSummaryRead {
    private var pending: CheckedContinuation<[UsageDailySummary], Never>?
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?

    func read() async -> [UsageDailySummary] {
        started = true
        waiter?.resume()
        waiter = nil
        return await withCheckedContinuation { pending = $0 }
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { waiter = $0 }
    }

    func finish(with summaries: [UsageDailySummary]) {
        pending?.resume(returning: summaries)
        pending = nil
    }

    func reset() { started = false }
}
