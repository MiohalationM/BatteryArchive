import Foundation
import Testing
@testable import BatteryBar

@Suite struct UsageDateWindowTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return value
    }
    private func date(_ day: Int) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 10, day: day, hour: 12))!
    }

    @Test func firstDayIsTheOnlyColumnAndHasNoPrehistory() {
        let window = UsageDateWindow(firstRecordedAt: date(25), selectedDate: date(25), now: date(25), calendar: calendar)
        #expect(window.days == [calendar.startOfDay(for: date(25))])
        #expect(window.pageIndex == 0 && window.lastPageIndex == 0)
    }

    @Test func subsequentDaysKeepGapsAndPaginateFromFirstRecord() {
        let first = date(10)
        let firstPage = UsageDateWindow(firstRecordedAt: first, selectedDate: date(11), now: date(18), calendar: calendar)
        #expect(firstPage.days == (10...16).map { calendar.startOfDay(for: date($0)) })
        let next = UsageDateWindow(firstRecordedAt: first, selectedDate: date(18), now: date(18), calendar: calendar)
        #expect(next.days == (17...18).map { calendar.startOfDay(for: date($0)) })
        #expect(next.pageIndex == 1 && next.lastPageIndex == 1)
    }

    @Test func missingHistoryStartsTodayAndSelectionClamps() {
        let empty = UsageDateWindow(firstRecordedAt: nil, selectedDate: date(1), now: date(25), calendar: calendar)
        #expect(empty.selectedDay == calendar.startOfDay(for: date(25)))
        #expect(empty.days.count == 1)
        let clamped = UsageDateWindow(firstRecordedAt: date(20), selectedDate: date(1), now: date(25), calendar: calendar)
        #expect(clamped.selectedDay == calendar.startOfDay(for: date(20)))
    }

    @Test func daylightSavingUsesCalendarDays() {
        let start = calendar.date(from: DateComponents(year: 2026, month: 10, day: 31, hour: 12))!
        let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
        let window = UsageDateWindow(firstRecordedAt: start, selectedDate: now, now: now, calendar: calendar)
        #expect(window.days.count == 3)
        #expect(window.days[2].timeIntervalSince(window.days[1]) == 25 * 3_600)
    }

    @Test func permanentDateWindowCanReachBeyondThirtyDays() {
        let now = date(25)
        let first = now.addingTimeInterval(-100 * 86_400)
        let window = UsageDateWindow(firstRecordedAt: first, selectedDate: first,
                                     now: now, calendar: calendar, retentionDays: nil)
        #expect(window.firstDay == calendar.startOfDay(for: first))
        #expect(window.days.count == 7 && window.lastPageIndex == 14)
    }
}

@Suite struct UsageTelemetryAggregatorTests {
    private let zero = Date(timeIntervalSince1970: 1_800_000_000)
    private var utc: TimeZone { TimeZone(secondsFromGMT: 0)! }

    private func read(
        _ aggregator: inout UsageTelemetryAggregator, _ seconds: Double,
        external: Bool? = false, screen: Bool? = true, watts: Double? = 6,
        level: Double? = 80, estimated: Bool = false
    ) {
        aggregator.observe(.init(date: zero.addingTimeInterval(seconds),
                                externalConnected: external, screenOn: screen, level: level,
                                dischargePower: watts, powerIsEstimated: estimated,
                                expectedInterval: 15, timeZone: utc))
    }

    @Test func tenMinutesAtSixWattsAndScreenSplit() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        for second in stride(from: 0.0, through: 600, by: 15) {
            read(&aggregator, second, screen: second < 420)
        }
        aggregator.stop(at: zero.addingTimeInterval(600))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.allSatisfy { $0.isValid })
        #expect(abs(buckets.reduce(0) { $0 + $1.dischargeWh } - 1) < 1e-9)
        #expect(buckets.reduce(0) { $0 + $1.screenOnSeconds } == 420)
        #expect(buckets.reduce(0) { $0 + $1.screenOffSeconds } == 180)
        #expect(buckets.reduce(0) { $0 + $1.powerSeconds } == 600)
    }

    @Test func twoMinuteUnplugWithNoPercentageDropIsSavedImmediately() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 0, external: true)
        for second in stride(from: 15.0, through: 135, by: 15) {
            read(&aggregator, second)
        }
        read(&aggregator, 135, external: true)
        let buckets = aggregator.takeCompleted()
        #expect(buckets.reduce(0) { $0 + $1.batterySeconds } == 120)
        #expect(abs(buckets.reduce(0) { $0 + $1.dischargeWh } - 0.2) < 1e-9)
        #expect(buckets.flatMap(\.levels).allSatisfy { $0.level == 80 })
    }

    @Test func severalShortExcursionsRemainSeparateAndAddUp() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        for second in stride(from: 0.0, through: 300, by: 15) {
            let battery = second < 120 || (second >= 180 && second < 240)
            read(&aggregator, second, external: !battery, watts: 6)
        }
        aggregator.stop(at: zero.addingTimeInterval(300))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.reduce(0) { $0 + $1.batterySeconds } == 180)
        #expect(buckets.reduce(0) { $0 + $1.onPowerSeconds } == 120)
        #expect(abs(buckets.reduce(0) { $0 + $1.dischargeWh } - 0.3) < 1e-9)
        let sessions = Set(buckets.flatMap(\.spans).compactMap(\.sessionID))
        #expect(sessions.count == 2)
    }

    @Test func gapDoesNotExtrapolateAndBreaksTheSeriesAndSession() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 0)
        read(&aggregator, 150)
        read(&aggregator, 180)
        aggregator.stop(at: zero.addingTimeInterval(180))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.reduce(0) { $0 + $1.batterySeconds } == 60)
        #expect(buckets.reduce(0) { $0 + $1.unknownSeconds } == 120)
        #expect(abs(buckets.reduce(0) { $0 + $1.dischargeWh } - 0.1) < 1e-9)
        #expect(Set(buckets.flatMap(\.levels).map(\.continuityID)).count == 2)
        #expect(Set(buckets.flatMap(\.spans).compactMap(\.sessionID)).count == 2)
    }

    @Test func realZeroAndUnavailableAreDifferent() {
        var valid = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&valid, 0, watts: 0)
        read(&valid, 30, watts: 0)
        valid.stop(at: zero.addingTimeInterval(30))
        let zeroBuckets = valid.takeCompleted()
        #expect(zeroBuckets.reduce(0) { $0 + $1.powerSeconds } == 30)
        #expect(zeroBuckets.reduce(0) { $0 + $1.dischargeWh } == 0)
        var missing = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&missing, 0, watts: nil)
        read(&missing, 30, watts: nil)
        missing.stop(at: zero.addingTimeInterval(30))
        let missingBuckets = missing.takeCompleted()
        #expect(missingBuckets.reduce(0) { $0 + $1.powerSeconds } == 0)
        #expect(missingBuckets.reduce(0) { $0 + $1.batterySeconds } == 30)
    }

    @Test func pluggedAtLimitNeverCountsAsBatteryUsageOrDischarge() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        for second in stride(from: 0.0, through: 600, by: 15) {
            read(&aggregator, second, external: true, watts: 20, level: 80)
        }
        aggregator.stop(at: zero.addingTimeInterval(600))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.reduce(0) { $0 + $1.onPowerSeconds } == 600)
        #expect(buckets.reduce(0) { $0 + $1.batterySeconds + $1.dischargeWh } == 0)
    }

    @Test func eightHourSleepHasNoPowerOrScreenTimeAndNoCrossSleepSession() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 0)
        aggregator.sleep(at: zero.addingTimeInterval(15))
        aggregator.wake(at: zero.addingTimeInterval(28_815))
        read(&aggregator, 28_815)
        aggregator.stop(at: zero.addingTimeInterval(28_830))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.allSatisfy { $0.isValid })
        #expect(buckets.reduce(0) { $0 + $1.sleepSeconds } == 28_800)
        #expect(buckets.reduce(0) { $0 + $1.screenOnSeconds } == 30)
        #expect(abs(buckets.reduce(0) { $0 + $1.dischargeWh } - 0.05) < 1e-9)
        #expect(Set(buckets.flatMap(\.spans).compactMap(\.sessionID)).count == 2)
    }

    @Test func unpairedSleepAndPostStopReadCannotInventUsage() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 0)
        aggregator.sleep(at: zero.addingTimeInterval(15))
        aggregator.stop(at: zero.addingTimeInterval(3_615))
        let before = aggregator.takeCompleted()
        read(&aggregator, 3_630)
        aggregator.stop(at: zero.addingTimeInterval(3_645))
        #expect(before.reduce(0) { $0 + $1.sleepSeconds } == 0)
        #expect(aggregator.takeCompleted().isEmpty)
    }

    @Test func previewDoesNotMutateOrCreatePersistableProjectedRecords() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 0)
        let a = aggregator.preview(at: zero.addingTimeInterval(15))
        let b = aggregator.preview(at: zero.addingTimeInterval(15))
        #expect(a == b)
        #expect(a.allSatisfy { $0.isLive })
        #expect(aggregator.takeCompleted().isEmpty)
        read(&aggregator, 15)
        aggregator.stop(at: zero.addingTimeInterval(15))
        #expect(aggregator.takeCompleted().reduce(0) { $0 + $1.batterySeconds } == 15)
    }

    @Test func screenEventCannotRefreshAnExpiredPowerObservation() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 0)
        aggregator.changeScreen(on: false, at: zero.addingTimeInterval(120))
        aggregator.stop(at: zero.addingTimeInterval(150))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.reduce(0) { $0 + $1.powerSeconds } == 30)
        #expect(buckets.reduce(0) { $0 + $1.screenOffSeconds } == 0)
    }

    @Test func detailArraysStayBoundedWhileTotalsRemainExact() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        for index in 0...1_000 {
            read(&aggregator, Double(index) / 10, screen: index.isMultiple(of: 2), level: Double(index % 100))
        }
        aggregator.stop(at: zero.addingTimeInterval(100))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.allSatisfy { $0.levels.count <= 64 && $0.spans.count <= 64 && $0.isValid })
        #expect(buckets.contains { $0.detailsTruncated })
        #expect(abs(buckets.reduce(0) { $0 + $1.batterySeconds } - 100) < 1e-7)
    }

    @Test func localMidnightSplitsBuckets() throws {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        let start = try #require(ISO8601DateFormatter().date(from: "2026-10-25T23:59:45Z"))
        for second in [0.0, 15, 30] {
            aggregator.observe(.init(date: start.addingTimeInterval(second),
                                    externalConnected: false, screenOn: true, level: 80,
                                    dischargePower: 6, timeZone: utc))
        }
        aggregator.stop(at: start.addingTimeInterval(30))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.count == 2)
        #expect(buckets.allSatisfy { $0.isValid })
        #expect(buckets.map(\.batterySeconds) == [15, 15])
    }

    @Test func previewAcrossWindowBoundaryHasStableIDs() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 295)
        let a = aggregator.preview(at: zero.addingTimeInterval(310))
        let b = aggregator.preview(at: zero.addingTimeInterval(310))
        #expect(a == b)
        #expect(aggregator.takeCompleted().isEmpty)
    }

    @Test func sourceUnknownDoesNotBecomeBatteryAndEstimatedPowerIsFlagged() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 0, external: nil)
        read(&aggregator, 30, estimated: true)
        read(&aggregator, 60, estimated: true)
        aggregator.stop(at: zero.addingTimeInterval(60))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.reduce(0) { $0 + $1.batterySeconds } == 30)
        #expect(buckets.reduce(0) { $0 + $1.estimatedSeconds } == 30)
        // The initial all-unknown bucket is omitted; the daily query accounts
        // for that wall-clock gap instead of persisting an invented zero.
        #expect(buckets.first?.start == zero.addingTimeInterval(30))
    }

    @Test func invalidationAndCadenceChangeDoNotExtendOldHold() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        aggregator.observe(.init(date: zero, externalConnected: false, screenOn: true,
                                level: 80, dischargePower: 6, expectedInterval: 5, timeZone: utc))
        aggregator.invalidate(at: zero.addingTimeInterval(5))
        read(&aggregator, 60)
        aggregator.stop(at: zero.addingTimeInterval(90))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.reduce(0) { $0 + $1.powerSeconds } == 35)
        #expect(buckets.reduce(0) { $0 + $1.batterySeconds } == 35)
    }

    @Test func timeZoneChangeClosesOldBucketAndStartsNewContinuity() {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        read(&aggregator, 0)
        aggregator.observe(.init(date: zero.addingTimeInterval(15), externalConnected: false,
                                screenOn: true, level: 80, dischargePower: 6,
                                timeZone: TimeZone(identifier: "Asia/Shanghai")!))
        aggregator.stop(at: zero.addingTimeInterval(30))
        let buckets = aggregator.takeCompleted()
        #expect(buckets.count == 2)
        #expect(Set(buckets.map(\.timeZoneID)) == ["GMT", "Asia/Shanghai"])
        #expect(Set(buckets.flatMap(\.levels).map(\.continuityID)).count == 2)
    }
}

@Suite struct UsageHistoryStoreTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BA-UsageTests-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func bucket(at date: Date) -> UsageBucket {
        var result = UsageBucket(measurementEpoch: UUID(), runID: UUID(), timeZoneID: "GMT",
                                 start: date, end: date.addingTimeInterval(30))
        result.screenOnSeconds = 30
        result.powerSeconds = 30
        result.dischargeWh = 0.05
        return result
    }

    @Test func appendIsIdempotentAndJournalDoesNotRewriteEachTime() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(directory: dir, now: now)
        let a = bucket(at: now.addingTimeInterval(-90))
        let b = bucket(at: now.addingTimeInterval(-60))
        store.append([a], now: now)
        let inode = try FileManager.default.attributesOfItem(atPath: store.journalURL.path)[.systemFileNumber] as? NSNumber
        store.append([a, b], now: now)
        #expect(store.lastError == nil)
        #expect(try FileManager.default.attributesOfItem(atPath: store.journalURL.path)[.systemFileNumber] as? NSNumber == inode)
        let interval = DateInterval(start: now.addingTimeInterval(-120), end: now)
        #expect(store.read(in: interval, now: now).buckets.count == 2)
        #expect(UsageHistoryStore(directory: dir, now: now).measurementEpoch == store.measurementEpoch)
    }

    @Test func corruptTailIsIsolatedAndFutureAppendGetsItsOwnLine() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(directory: dir, now: now)
        store.append([bucket(at: now.addingTimeInterval(-90))], now: now)
        let handle = try FileHandle(forWritingTo: store.journalURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{unfinished".utf8))
        try handle.close()
        let restored = UsageHistoryStore(directory: dir, now: now)
        restored.append([bucket(at: now.addingTimeInterval(-60))], now: now)
        let interval = DateInterval(start: now.addingTimeInterval(-120), end: now)
        let reloaded = UsageHistoryStore(directory: dir, now: now).read(in: interval, now: now)
        #expect(reloaded.buckets.count == 2)
        #expect(reloaded.skippedLines == 1)
    }

    @Test func expiredRecordsCompactOnlyAfterThreshold() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("usage-history.jsonl")
        var data = Data()
        for index in 0..<61 {
            data.append(try JSONEncoder().encode(bucket(at: now.addingTimeInterval(-31 * 86_400 + Double(index) * 60))))
            data.append(0x0A)
        }
        try data.write(to: url)
        let store = UsageHistoryStore(directory: dir, now: now)
        store.append([bucket(at: now.addingTimeInterval(-60))], now: now)
        #expect(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count == 1)
    }

    @Test func corruptCheckpointPreservesExpiredJournalUntilRestartRecovery() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let oldStart = calendar.startOfDay(for: now.addingTimeInterval(-31 * 86_400))
            .addingTimeInterval(3_600)
        let oldNow = oldStart.addingTimeInterval(61 * 60)
        let original = UsageHistoryStore(directory: dir, now: oldNow)
        let oldBuckets = (0..<61).map { index in
            var value = bucket(at: oldStart.addingTimeInterval(Double(index) * 60))
            value.measurementEpoch = original.measurementEpoch
            return value
        }
        original.append([oldBuckets[0]], now: oldNow)
        let dailyDirectory = dir.appendingPathComponent("usage-daily")
        let checkpoint = try #require(FileManager.default.contentsOfDirectory(
            at: dailyDirectory, includingPropertiesForKeys: nil).first)
        let earlierCheckpoint = try Data(contentsOf: checkpoint)
        original.append(Array(oldBuckets.dropFirst()), now: oldNow)
        let oldJournal = try Data(contentsOf: original.journalURL)
        let damagedCheckpoint = Data("corrupt checkpoint".utf8)
        try damagedCheckpoint.write(to: checkpoint)

        let interval = DateInterval(start: now.addingTimeInterval(-180), end: now)
        let fresh = bucket(at: now.addingTimeInterval(-120))
        let restored = UsageHistoryStore(directory: dir, now: now)
        restored.append([fresh], now: now)
        #expect(restored.read(in: interval, now: now).error != nil)
        #expect(restored.read(in: interval, now: now).buckets.map(\.id) == [fresh.id])
        #expect(restored.dailySummaries().reduce(0) { $0 + $1.screenOnSeconds } == 30)
        #expect(try Data(contentsOf: checkpoint) == damagedCheckpoint)
        #expect(try Data(contentsOf: restored.journalURL).starts(with: oldJournal))
        #expect(try String(contentsOf: restored.journalURL, encoding: .utf8)
            .split(separator: "\n").count == 62)

        let stillDamaged = UsageHistoryStore(directory: dir, now: now)
        let secondFresh = bucket(at: now.addingTimeInterval(-90))
        stillDamaged.append([secondFresh], now: now)
        #expect(try Data(contentsOf: stillDamaged.journalURL).starts(with: oldJournal))
        #expect(try Data(contentsOf: checkpoint) == damagedCheckpoint)

        // Restoring a valid prefix lets the preserved journal recover the missing tail.
        try earlierCheckpoint.write(to: checkpoint, options: .atomic)
        let recovered = UsageHistoryStore(directory: dir, now: now)
        let recoveredOld = try #require(recovered.dailySummaries().first {
            $0.measurementEpoch == original.measurementEpoch
        })
        #expect(recoveredOld.screenOnSeconds == 61 * 30)
        #expect(abs(recoveredOld.dischargeWh - 61 * 0.05) < 1e-9)
        #expect(recovered.read(in: interval, now: now).error == nil)
        recovered.append([bucket(at: now.addingTimeInterval(-60))], now: now)
        #expect(try String(contentsOf: recovered.journalURL, encoding: .utf8)
            .split(separator: "\n").count == 3)
        let afterCompaction = UsageHistoryStore(directory: dir, now: now)
        let afterCompactionOld = try #require(afterCompaction.dailySummaries().first {
            $0.measurementEpoch == original.measurementEpoch
        })
        #expect(afterCompactionOld == recoveredOld)
        #expect(afterCompaction.read(in: interval, now: now).buckets.count == 3)
    }

    @Test func narrowQueryIgnoresOldCycleFileAndOtherDays() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let old = dir.appendingPathComponent("cycles.json")
        let oldData = Data("unreadable retired data".utf8)
        try oldData.write(to: old)
        let store = UsageHistoryStore(directory: dir, now: now)
        let yesterday = bucket(at: now.addingTimeInterval(-86_400))
        let today = bucket(at: now.addingTimeInterval(-60))
        store.append([yesterday, today], now: now)
        let page = store.read(in: DateInterval(start: now.addingTimeInterval(-120), end: now), now: now)
        #expect(page.buckets.map(\.id) == [today.id])
        #expect(page.availableTimeZones == ["GMT"])
        let restored = UsageHistoryStore(directory: dir, now: now)
        #expect(restored.dailySummaries().map(\.firstRecord).min() == yesterday.start)
        #expect(try Data(contentsOf: old) == oldData)
    }

    @Test func overlappingBucketDoesNotDoubleCountAndLiveIsNotPersisted() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(directory: dir, now: now)
        let a = bucket(at: now.addingTimeInterval(-90))
        store.append([a], now: now)
        store.append([bucket(at: now.addingTimeInterval(-80))], now: now)
        #expect(store.lastError != nil)
        var live = bucket(at: now.addingTimeInterval(-30))
        live.isLive = true
        store.append([live], now: now)
        let page = store.read(in: DateInterval(start: now.addingTimeInterval(-120), end: now), now: now)
        #expect(page.buckets.count == 1)
    }

    @Test func overlappingBatchKeepsLaterValidBucketsAndRestartTotals() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(directory: dir, now: now)
        let epoch = store.measurementEpoch
        func value(_ offset: Double) -> UsageBucket {
            var result = bucket(at: now.addingTimeInterval(offset))
            result.measurementEpoch = epoch
            return result
        }
        let first = value(-150)
        let beforeOverlap = value(-120)
        let overlapping = value(-105)
        let afterOverlap = value(-90)
        store.append([first], now: now)
        store.append([beforeOverlap, overlapping, afterOverlap], now: now)
        let interval = DateInterval(start: now.addingTimeInterval(-180), end: now)
        let page = store.read(in: interval, now: now)
        #expect(page.error != nil)
        #expect(page.buckets.map(\.id) == [first.id, beforeOverlap.id, afterOverlap.id])
        #expect(store.dailySummaries().reduce(0) { $0 + $1.screenOnSeconds } == 90)

        let restored = UsageHistoryStore(directory: dir, now: now)
        restored.append([first, beforeOverlap, afterOverlap], now: now)
        #expect(restored.read(in: interval, now: now).buckets.map(\.id)
            == [first.id, beforeOverlap.id, afterOverlap.id])
        #expect(restored.dailySummaries().reduce(0) { $0 + $1.screenOnSeconds } == 90)
        #expect(abs(restored.dailySummaries().reduce(0) { $0 + $1.dischargeWh } - 0.15) < 1e-9)
    }

    @Test func hardCapBoundsReloadAndRangeQueries() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = UsageHistoryStore(directory: dir, now: now)
        let count = UsageHistoryStore.hardCap + 2
        let all = (0..<count).map { index in
            bucket(at: now.addingTimeInterval(Double(index - count) * 30))
        }
        store.append(all, now: now)
        let range = DateInterval(start: now.addingTimeInterval(-UsageHistoryStore.retention), end: now)
        let loaded = UsageHistoryStore(directory: dir, now: now)
        #expect(loaded.read(in: range, now: now).buckets.count == UsageHistoryStore.hardCap)
        #expect(loaded.read(in: DateInterval(start: now.addingTimeInterval(-120), end: now), now: now).buckets.count == 4)
    }

    private func onPowerBuckets(duration: Double) -> [UsageBucket] {
        let utc = TimeZone(secondsFromGMT: 0)!
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        for second in stride(from: 0.0, through: duration, by: 15) {
            aggregator.observe(.init(date: now.addingTimeInterval(second), externalConnected: true,
                                     screenOn: true, level: 80, dischargePower: nil, timeZone: utc))
        }
        aggregator.stop(at: now.addingTimeInterval(duration))
        return aggregator.takeCompleted()
    }

    @Test func dailyPersistenceSurvivesRestartAndDetailExpirationWithoutDoubleCount() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let end = now.addingTimeInterval(3_600)
        let buckets = onPowerBuckets(duration: 3_600)
        let store = UsageHistoryStore(directory: dir, now: end)
        store.append(buckets, now: end)
        store.append(buckets, now: end)
        #expect(store.dailySummaries().reduce(0) { $0 + $1.onPowerSeconds } == 3_600)
        let later = end.addingTimeInterval(40 * 86_400)
        let restored = UsageHistoryStore(directory: dir, now: later)
        #expect(restored.read(in: DateInterval(start: now, end: end), now: later).buckets.isEmpty)
        #expect(restored.dailySummaries().allSatisfy { $0.isValid })
        #expect(restored.dailySummaries().reduce(0) { $0 + $1.onPowerSeconds } == 3_600)
    }

    @Test func journalCanRecoverUnwrittenDailySummary() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let buckets = onPowerBuckets(duration: 600)
        var journal = Data()
        for bucket in buckets { journal.append(try JSONEncoder().encode(bucket)); journal.append(0x0A) }
        try journal.write(to: dir.appendingPathComponent("usage-history.jsonl"))
        for _ in 0..<2 {
            let store = UsageHistoryStore(directory: dir, now: now.addingTimeInterval(600))
            #expect(store.dailySummaries().reduce(0) { $0 + $1.onPowerSeconds } == 600)
        }
    }

    @Test func recoveryAppliesOnlyBucketsAfterTheDailyCheckpoint() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let buckets = onPowerBuckets(duration: 600)
        let store = UsageHistoryStore(directory: dir, now: now.addingTimeInterval(600))
        store.append([buckets[0]], now: now.addingTimeInterval(600))
        let handle = try FileHandle(forWritingTo: store.journalURL)
        try handle.seekToEnd()
        for bucket in buckets.dropFirst() {
            var line = try JSONEncoder().encode(bucket); line.append(0x0A)
            try handle.write(contentsOf: line)
        }
        try handle.close()
        let restored = UsageHistoryStore(directory: dir, now: now.addingTimeInterval(600))
        #expect(restored.dailySummaries().reduce(0) { $0 + $1.onPowerSeconds } == 600)
    }

    @Test func livePreviewIsMergedOnceAndNeverPersisted() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let utc = TimeZone(secondsFromGMT: 0)!
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        aggregator.observe(.init(date: now, externalConnected: true, screenOn: true, level: 80, timeZone: utc))
        aggregator.observe(.init(date: now.addingTimeInterval(15), externalConnected: true, screenOn: true, level: 80, timeZone: utc))
        let live = aggregator.preview(at: now.addingTimeInterval(30))
        let merged = UsageDailySummary.merging([], live: live + live, zone: utc.identifier)
        #expect(merged.reduce(0) { $0 + $1.onPowerSeconds } == 30)
        let store = UsageHistoryStore(directory: dir, now: now.addingTimeInterval(30))
        store.append(live, now: now.addingTimeInterval(30))
        #expect(store.dailySummaries().isEmpty)
    }

    @Test func legacyInputEnergyJSONFieldsDecodeCleanly() throws {
        let sample = onPowerBuckets(duration: 30)[0]
        let encoded = try JSONEncoder().encode(sample)
        var bucketJSON = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        bucketJSON["inputWh"] = 0.5
        bucketJSON["inputSeconds"] = 30.0
        let decodedBucket = try JSONDecoder().decode(
            UsageBucket.self,
            from: JSONSerialization.data(withJSONObject: bucketJSON)
        )
        #expect(decodedBucket == sample)
        #expect(decodedBucket.isValid)

        var summary = UsageDailySummary(bucket: sample)
        summary.include(sample)
        var summaryJSON = try #require(
            JSONSerialization.jsonObject(with: try JSONEncoder().encode(summary)) as? [String: Any]
        )
        summaryJSON["inputWh"] = 0.5
        summaryJSON["inputSeconds"] = 30.0
        let decodedSummary = try JSONDecoder().decode(
            UsageDailySummary.self,
            from: JSONSerialization.data(withJSONObject: summaryJSON)
        )
        #expect(decodedSummary == summary)
        #expect(decodedSummary.isValid)
    }

    @Test func midnightAndTimeZonesProduceSeparateDailyTotals() {
        let utc = TimeZone(secondsFromGMT: 0)!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = utc
        let midnight = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: now))!
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        for offset in stride(from: -30.0, through: 30, by: 15) {
            aggregator.observe(.init(date: midnight.addingTimeInterval(offset), externalConnected: true,
                                     screenOn: true, level: 80, dischargePower: nil, timeZone: utc))
        }
        aggregator.stop(at: midnight.addingTimeInterval(30))
        let summaries = UsageDailySummary.merging([], live: aggregator.takeCompleted(), zone: utc.identifier)
        #expect(summaries.count == 2)
        #expect(summaries.allSatisfy { $0.onPowerSeconds == 30 })
        #expect(UsageDailySummary.merging(summaries, live: [], zone: "Asia/Shanghai").isEmpty)
    }
}

@Suite struct UsageHistoryAnalysisTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func emptyDayIsUnknownNotMeasuredZero() {
        let result = UsageHistoryAnalysis.reviews(stored: [], live: [], dates: [now], calendar: utc, now: now)
        #expect(result.count == 1)
        #expect(!result[0].hasEvidence)
        #expect(result[0].powerCoverage == nil)
        #expect(result[0].unknownSeconds > 0)
    }

    @Test func shortNoDropSessionsRemainVisibleAndLiveCopyIsDeduplicated() throws {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        let begin = now.addingTimeInterval(-120)
        for seconds in stride(from: 0.0, through: 120, by: 15) {
            aggregator.observe(.init(date: begin.addingTimeInterval(seconds), externalConnected: false,
                                    screenOn: true, level: 80, dischargePower: 6, timeZone: utc.timeZone))
        }
        let live = aggregator.preview(at: now)
        var duplicate = live
        for index in duplicate.indices { duplicate[index].isLive = false }
        let review = try #require(UsageHistoryAnalysis.reviews(stored: duplicate, live: live,
                                                              dates: [now], calendar: utc, now: now).first)
        #expect(review.screenOnSeconds == 120)
        #expect(review.sessions.count == 1)
        #expect(review.sessions[0].startLevel == 80 && review.sessions[0].endLevel == 80)
        #expect(review.sessions[0].ongoing)
        #expect(abs(review.dischargeWh - 0.2) < 1e-9)
    }

    @Test func dayLengthUsesCalendarAcrossDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Los_Angeles"))
        let spring = try #require(ISO8601DateFormatter().date(from: "2026-03-08T12:00:00Z"))
        let fall = try #require(ISO8601DateFormatter().date(from: "2026-11-01T12:00:00Z"))
        let future = try #require(ISO8601DateFormatter().date(from: "2026-11-03T12:00:00Z"))
        let reviews = UsageHistoryAnalysis.reviews(stored: [], live: [], dates: [spring, fall], calendar: calendar, now: future)
        #expect(reviews[0].elapsedSeconds == 23 * 3_600)
        #expect(reviews[1].elapsedSeconds == 25 * 3_600)
    }

    @Test func restartAndMissingSamplesDoNotConnectLinesOrSessions() throws {
        var a = UsageTelemetryAggregator(measurementEpoch: UUID())
        var b = UsageTelemetryAggregator(measurementEpoch: UUID())
        for offset in [120.0, 105] {
            a.observe(.init(date: now.addingTimeInterval(-offset), externalConnected: false,
                            screenOn: true, level: 80, dischargePower: nil, timeZone: utc.timeZone))
        }
        a.stop(at: now.addingTimeInterval(-90))
        for offset in [30.0, 15] {
            b.observe(.init(date: now.addingTimeInterval(-offset), externalConnected: false,
                            screenOn: true, level: 79, dischargePower: nil, timeZone: utc.timeZone))
        }
        b.stop(at: now)
        let review = try #require(UsageHistoryAnalysis.reviews(stored: a.takeCompleted() + b.takeCompleted(),
                                                              live: [], dates: [now], calendar: utc, now: now).first)
        #expect(review.sessions.count == 2)
        #expect(Set(review.levels.map(\.segment)).count == 2)
        #expect(!review.canRankSessions)
        #expect(review.powerSeconds == 0)
    }

    @Test func incompletePowerCoverageUsesKnownBatteryTimeAsDenominator() throws {
        var aggregator = UsageTelemetryAggregator(measurementEpoch: UUID())
        for second in stride(from: 0.0, through: 600, by: 15) {
            aggregator.observe(.init(date: now.addingTimeInterval(second - 600),
                                    externalConnected: false, screenOn: true, level: 80,
                                    dischargePower: second < 300 ? 6 : nil, timeZone: utc.timeZone))
        }
        aggregator.stop(at: now)
        let review = try #require(UsageHistoryAnalysis.reviews(stored: aggregator.takeCompleted(),
                                                              live: [], dates: [now], calendar: utc, now: now).first)
        #expect(review.powerCoverage == 0.5)
        #expect(abs(review.dischargeWh - 0.5) < 1e-9)
        #expect(!review.canRankSessions)
    }
}
