import Foundation
import Testing
@testable import BatteryArchive

@Suite struct BatteryHealthHistoryTests {
    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryHealthTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeDate(
        year: Int,
        month: Int,
        day: Int,
        hour: Int = 12,
        minute: Int = 0,
        calendar: Calendar = utcCalendar
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        return calendar.date(from: components)!
    }

    private func makeRecord(
        dayKey: String,
        recordedAt: Date? = nil,
        systemHealthPercent: Double? = 96,
        fullChargeCapacityMah: Int? = 4100,
        nominalCapacityMah: Int? = 4150,
        designCapacityMah: Int = 4382,
        cycleCount: Int = 80,
        designCycleCount: Int? = 1000,
        peakTemperatureC: Double? = 32.5,
        schemaVersion: Int = 1
    ) -> BatteryHealthRecord {
        let fallbackDate = BatteryHealthRecord.parseDayKey(dayKey, calendar: Self.utcCalendar)
            ?? Date(timeIntervalSince1970: 1_800_000_000)
        return BatteryHealthRecord(
            schemaVersion: schemaVersion,
            dayKey: dayKey,
            recordedAt: recordedAt ?? fallbackDate,
            systemHealthPercent: systemHealthPercent,
            fullChargeCapacityMah: fullChargeCapacityMah,
            nominalCapacityMah: nominalCapacityMah,
            designCapacityMah: designCapacityMah,
            cycleCount: cycleCount,
            designCycleCount: designCycleCount,
            peakTemperatureC: peakTemperatureC
        )
    }

    @Test func recordValidationAndCapacityRatio() {
        let calendar = Self.utcCalendar
        let sampleDate = makeDate(year: 2026, month: 6, day: 15, hour: 14, minute: 30, calendar: calendar)
        let key = BatteryHealthRecord.dayKey(for: sampleDate, calendar: calendar)
        #expect(key == "2026-06-15")

        let valid = makeRecord(
            dayKey: key,
            recordedAt: sampleDate,
            systemHealthPercent: 95,
            fullChargeCapacityMah: 3992,
            nominalCapacityMah: 4122,
            designCapacityMah: 4382,
            cycleCount: 120,
            designCycleCount: 1000,
            peakTemperatureC: 33.4
        )
        #expect(valid.isValid)
        #expect(valid.id == "2026-06-15")
        #expect(valid.parsedDate(calendar: calendar) == calendar.startOfDay(for: sampleDate))
        let expectedRatio = 3992.0 / 4382.0 * 100.0
        #expect(abs((valid.capacityRatioPercent ?? 0) - expectedRatio) < 1e-9)

        // Minimal valid record with nil optionals
        let minimal = BatteryHealthRecord(
            dayKey: "2026-06-15",
            recordedAt: sampleDate,
            designCapacityMah: 4382,
            cycleCount: 0
        )
        #expect(minimal.isValid)
        #expect(minimal.capacityRatioPercent == nil)

        // Physical boundaries: 100% health, negative winter temp, new battery slightly above design capacity
        let boundary = makeRecord(
            dayKey: "2024-02-29",
            systemHealthPercent: 100,
            fullChargeCapacityMah: Int(Double(4382) * 1.15),
            nominalCapacityMah: Int(Double(4382) * 1.15),
            designCapacityMah: 4382,
            cycleCount: 10_000,
            designCycleCount: 10_000,
            peakTemperatureC: -20
        )
        #expect(boundary.isValid)

        // Invalid schema version
        #expect(!makeRecord(dayKey: "2026-06-15", schemaVersion: 2).isValid)

        // Invalid dayKeys
        for badKey in ["2026-02-30", "2026-13-01", "2026-6-15", "2026/06/15", "invalid", "2026-06-15 "] {
            #expect(!makeRecord(dayKey: badKey).isValid)
        }

        // Out-of-bounds required & optional fields
        #expect(!makeRecord(dayKey: "2026-06-15", designCapacityMah: 0).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", designCapacityMah: 100_001).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", cycleCount: -1).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", cycleCount: 10_001).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", systemHealthPercent: 0).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", systemHealthPercent: 100.1).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", systemHealthPercent: .nan).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", systemHealthPercent: .infinity).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", fullChargeCapacityMah: 0).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", fullChargeCapacityMah: 5_100, designCapacityMah: 4382).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", nominalCapacityMah: 0).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", nominalCapacityMah: 5_100, designCapacityMah: 4382).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", designCycleCount: 0).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", designCycleCount: 10_001).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", peakTemperatureC: -20.1).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", peakTemperatureC: 100.1).isValid)
        #expect(!makeRecord(dayKey: "2026-06-15", peakTemperatureC: .nan).isValid)
    }

    @Test func storeDailyMergePreservesSystemHealthDesignCycleAndTracksPeakTemperature() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Self.utcCalendar
        let store = BatteryHealthStore(directory: dir)

        let t1 = makeDate(year: 2026, month: 8, day: 10, hour: 9, calendar: calendar)
        let t2 = makeDate(year: 2026, month: 8, day: 10, hour: 10, calendar: calendar)
        let t3 = makeDate(year: 2026, month: 8, day: 10, hour: 14, calendar: calendar)

        // First read (IORegistry before system_profiler completes): systemHealthPercent is nil
        #expect(store.record(
            date: t1,
            systemHealthPercent: nil,
            fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120,
            designCapacityMah: 4382,
            cycleCount: 150,
            designCycleCount: 1000,
            temperatureC: 31.0,
            calendar: calendar
        ))

        // Second read (system_profiler arrives with 95%, cooler temperature must not lower peak)
        #expect(store.record(
            date: t2,
            systemHealthPercent: 95.0,
            fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120,
            designCapacityMah: 4382,
            cycleCount: 150,
            designCycleCount: 1000,
            temperatureC: 28.5,
            calendar: calendar
        ))

        // Third read (systemHealthPercent nil and designCycleCount nil, warmer temperature)
        #expect(store.record(
            date: t3,
            systemHealthPercent: nil,
            fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120,
            designCapacityMah: 4382,
            cycleCount: 150,
            designCycleCount: nil,
            temperatureC: 35.2,
            calendar: calendar
        ))

        let records = store.allRecords()
        #expect(records.count == 1)
        #expect(records[0].dayKey == "2026-08-10")
        #expect(records[0].systemHealthPercent == 95.0)
        #expect(records[0].designCycleCount == 1000)
        #expect(records[0].peakTemperatureC == 35.2)

        // Persists identically across reload
        let reloaded = BatteryHealthStore(directory: dir)
        #expect(reloaded.allRecords() == records)
    }

    @Test func storeDebounceSkipsMinorJitterAndWritesSignificantChanges() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Self.utcCalendar
        let store = BatteryHealthStore(directory: dir)
        let day = makeDate(year: 2026, month: 8, day: 12, hour: 10, calendar: calendar)

        func lineCount() throws -> Int {
            try String(contentsOf: store.fileURL, encoding: .utf8)
                .split(separator: "\n")
                .count
        }

        // Invalid designCapacity rejected without creating file
        #expect(!store.record(
            date: day, systemHealthPercent: 96, fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4100, designCapacityMah: 0, cycleCount: 10,
            designCycleCount: 1000, temperatureC: 30, calendar: calendar
        ))
        #expect(!FileManager.default.fileExists(atPath: store.fileURL.path))

        // Initial write
        #expect(store.record(
            date: day, systemHealthPercent: 95, fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120, designCapacityMah: 4382, cycleCount: 120,
            designCycleCount: 1000, temperatureC: 32.2, calendar: calendar
        ))
        #expect(try lineCount() == 1)

        // Sub-threshold jitter across FCC (<10), nominal (<10), temp (<0.5), identical health/cycle/designCycle
        #expect(!store.record(
            date: day.addingTimeInterval(60), systemHealthPercent: 95, fullChargeCapacityMah: 4009,
            nominalCapacityMah: 4111, designCapacityMah: 4382, cycleCount: 120,
            designCycleCount: 1000, temperatureC: 32.69, calendar: calendar
        ))
        #expect(!store.record(
            date: day.addingTimeInterval(120), systemHealthPercent: nil, fullChargeCapacityMah: 3991,
            nominalCapacityMah: 4129, designCapacityMah: 4382, cycleCount: 120,
            designCycleCount: nil, temperatureC: 29.0, calendar: calendar
        ))
        #expect(try lineCount() == 1)
        // In-memory record preserves the observed 32.69°C peak even before disk flush
        #expect(store.allRecords()[0].peakTemperatureC == 32.69)

        // FCC delta == 10 triggers write (and flushes the preserved 32.69°C peak with it)
        #expect(store.record(
            date: day.addingTimeInterval(180), systemHealthPercent: 95, fullChargeCapacityMah: 4010,
            nominalCapacityMah: 4120, designCapacityMah: 4382, cycleCount: 120,
            designCycleCount: 1000, temperatureC: 32.2, calendar: calendar
        ))
        #expect(try lineCount() == 2)
        #expect(store.allRecords()[0].peakTemperatureC == 32.69)

        // Nominal delta == 10 triggers write
        #expect(store.record(
            date: day.addingTimeInterval(240), systemHealthPercent: 95, fullChargeCapacityMah: 4010,
            nominalCapacityMah: 4110, designCapacityMah: 4382, cycleCount: 120,
            designCycleCount: 1000, temperatureC: 32.2, calendar: calendar
        ))
        #expect(try lineCount() == 3)

        // Peak temperature increase == 0.5°C above persisted 32.69°C triggers write
        #expect(store.record(
            date: day.addingTimeInterval(300), systemHealthPercent: 95, fullChargeCapacityMah: 4010,
            nominalCapacityMah: 4110, designCapacityMah: 4382, cycleCount: 120,
            designCycleCount: 1000, temperatureC: 33.19, calendar: calendar
        ))
        #expect(try lineCount() == 4)

        // Cycle count increment triggers write
        #expect(store.record(
            date: day.addingTimeInterval(360), systemHealthPercent: 95, fullChargeCapacityMah: 4010,
            nominalCapacityMah: 4110, designCapacityMah: 4382, cycleCount: 121,
            designCycleCount: 1000, temperatureC: 33.19, calendar: calendar
        ))
        #expect(try lineCount() == 5)

        // System health change triggers write
        #expect(store.record(
            date: day.addingTimeInterval(420), systemHealthPercent: 94, fullChargeCapacityMah: 4010,
            nominalCapacityMah: 4110, designCapacityMah: 4382, cycleCount: 121,
            designCycleCount: 1000, temperatureC: 33.19, calendar: calendar
        ))
        #expect(try lineCount() == 6)

        // Design cycle count change triggers write
        #expect(store.record(
            date: day.addingTimeInterval(480), systemHealthPercent: 94, fullChargeCapacityMah: 4010,
            nominalCapacityMah: 4110, designCapacityMah: 4382, cycleCount: 121,
            designCycleCount: 1200, temperatureC: 33.19, calendar: calendar
        ))
        #expect(try lineCount() == 7)

        // Binary64 rounding edge case: 32.2 -> 32.7 (exact +0.5°C) must trigger write
        let nextDay = makeDate(year: 2026, month: 8, day: 13, hour: 10, calendar: calendar)
        #expect(store.record(
            date: nextDay, systemHealthPercent: 94, fullChargeCapacityMah: 4010,
            nominalCapacityMah: 4110, designCapacityMah: 4382, cycleCount: 121,
            designCycleCount: 1200, temperatureC: 32.2, calendar: calendar
        ))
        #expect(store.record(
            date: nextDay.addingTimeInterval(60), systemHealthPercent: 94, fullChargeCapacityMah: 4010,
            nominalCapacityMah: 4110, designCapacityMah: 4382, cycleCount: 121,
            designCycleCount: 1200, temperatureC: 32.7, calendar: calendar
        ))
        #expect(try lineCount() == 9)
    }

    @Test func storeSkipsCorruptLinesDeduplicatesAndRepairsMissingTrailingNewline() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Self.utcCalendar
        let fileURL = dir.appendingPathComponent("battery-health-history.jsonl")

        let encoder = JSONEncoder()
        let first = makeRecord(dayKey: "2026-08-01", systemHealthPercent: 97, fullChargeCapacityMah: 4100, cycleCount: 50)
        let newerSameDay = makeRecord(dayKey: "2026-08-01", systemHealthPercent: 96, fullChargeCapacityMah: 4080, cycleCount: 51)
        let invalidBounds = makeRecord(dayKey: "2026-08-02", designCapacityMah: 0, cycleCount: 52)

        var raw = Data()
        raw.append(try encoder.encode(first)); raw.append(0x0A)
        raw.append(Data("{not-valid-json\n".utf8))
        raw.append(try encoder.encode(invalidBounds)); raw.append(0x0A)
        raw.append(try encoder.encode(newerSameDay)); raw.append(0x0A)
        // Truncated tail line without trailing newline
        raw.append(Data("{\"schemaVersion\":1,\"dayKey\":\"2026-08".utf8))
        try raw.write(to: fileURL, options: .atomic)

        let store = BatteryHealthStore(directory: dir)
        #expect(store.skippedLines == 3)
        #expect(store.allRecords().count == 1)
        #expect(store.allRecords()[0].cycleCount == 51)
        #expect(store.allRecords()[0].systemHealthPercent == 96)

        // Appending a new day must insert separator newline so it isn't concatenated to truncated tail
        let day3 = makeDate(year: 2026, month: 8, day: 3, calendar: calendar)
        #expect(store.record(
            date: day3, systemHealthPercent: 96, fullChargeCapacityMah: 4075,
            nominalCapacityMah: 4120, designCapacityMah: 4382, cycleCount: 52,
            designCycleCount: 1000, temperatureC: 30.0, calendar: calendar
        ))

        let reloaded = BatteryHealthStore(directory: dir)
        #expect(reloaded.allRecords().map(\.dayKey) == ["2026-08-01", "2026-08-03"])
        #expect(reloaded.allRecords()[1].cycleCount == 52)
    }

    @Test func storeCompactsAtomicallyAndRetainsHistoryPermanently() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Self.utcCalendar
        let store = BatteryHealthStore(directory: dir)

        let twoYearsAgo = makeDate(year: 2024, month: 1, day: 15, calendar: calendar)
        let lastYear = makeDate(year: 2025, month: 10, day: 20, calendar: calendar)
        let today = makeDate(year: 2026, month: 11, day: 24, calendar: calendar)

        #expect(store.record(
            date: twoYearsAgo, systemHealthPercent: 100, fullChargeCapacityMah: 4350,
            nominalCapacityMah: 4380, designCapacityMah: 4382, cycleCount: 5,
            designCycleCount: 1000, temperatureC: 29.0, calendar: calendar
        ))
        #expect(store.record(
            date: lastYear, systemHealthPercent: 97, fullChargeCapacityMah: 4160,
            nominalCapacityMah: 4210, designCapacityMah: 4382, cycleCount: 90,
            designCycleCount: 1000, temperatureC: 32.0, calendar: calendar
        ))
        #expect(store.record(
            date: today, systemHealthPercent: 94, fullChargeCapacityMah: 3992,
            nominalCapacityMah: 4122, designCapacityMah: 4382, cycleCount: 170,
            designCycleCount: 1000, temperatureC: 31.0, calendar: calendar
        ))

        // 29 redundant updates on today stay below threshold (3 + 29 = 32 lines)
        for step in 1...29 {
            #expect(store.record(
                date: today.addingTimeInterval(TimeInterval(step * 60)),
                systemHealthPercent: 94, fullChargeCapacityMah: 3992,
                nominalCapacityMah: 4122, designCapacityMah: 4382,
                cycleCount: 170 + step, designCycleCount: 1000,
                temperatureC: 31.0, calendar: calendar
            ))
        }
        let linesBeforeCompact = try String(contentsOf: store.fileURL, encoding: .utf8)
            .split(separator: "\n").count
        #expect(linesBeforeCompact == 32)

        // 30th redundant update triggers atomic compaction back to 3 unique day lines
        #expect(store.record(
            date: today.addingTimeInterval(TimeInterval(30 * 60)),
            systemHealthPercent: 94, fullChargeCapacityMah: 3992,
            nominalCapacityMah: 4122, designCapacityMah: 4382,
            cycleCount: 200, designCycleCount: 1000,
            temperatureC: 31.0, calendar: calendar
        ))
        let linesAfterCompact = try String(contentsOf: store.fileURL, encoding: .utf8)
            .split(separator: "\n").count
        #expect(linesAfterCompact == 3)

        // Reload confirms permanent retention (no 30-day pruning) and latest merged state
        let reloaded = BatteryHealthStore(directory: dir)
        let records = reloaded.allRecords()
        #expect(records.map(\.dayKey) == ["2024-01-15", "2025-10-20", "2026-11-24"])
        #expect(records[2].cycleCount == 200)
    }

    @Test func trendAnalysisDefaultRangeAndFiltering() {
        let calendar = Self.utcCalendar
        let now = makeDate(year: 2026, month: 11, day: 24, hour: 15, calendar: calendar)

        func recordsSpanning(daysBack: [Int]) -> [BatteryHealthRecord] {
            daysBack.map { offset in
                let date = calendar.date(byAdding: .day, value: -offset, to: now)!
                let key = BatteryHealthRecord.dayKey(for: date, calendar: calendar)
                return makeRecord(dayKey: key, recordedAt: date, cycleCount: 100 - min(offset, 100))
            }
        }

        // Empty & single-day & < 30 days span default to .all
        #expect(BatteryHealthTrendAnalysis.defaultRange(for: [], now: now, calendar: calendar) == .all)
        #expect(BatteryHealthTrendAnalysis.defaultRange(for: recordsSpanning(daysBack: [0]), now: now, calendar: calendar) == .all)
        #expect(BatteryHealthTrendAnalysis.defaultRange(for: recordsSpanning(daysBack: [29, 0]), now: now, calendar: calendar) == .all)

        // >= 30 days span with recent data defaults to .days30
        #expect(BatteryHealthTrendAnalysis.defaultRange(for: recordsSpanning(daysBack: [30, 0]), now: now, calendar: calendar) == .days30)
        #expect(BatteryHealthTrendAnalysis.defaultRange(for: recordsSpanning(daysBack: [90, 45, 0]), now: now, calendar: calendar) == .days30)

        // Historical span with nothing in last 30 days falls back to .all instead of empty chart
        #expect(BatteryHealthTrendAnalysis.defaultRange(for: recordsSpanning(daysBack: [140, 100]), now: now, calendar: calendar) == .all)

        // Daily records for 400 days (0...399 days ago) plus an invalid record and unsorted input
        var daily = recordsSpanning(daysBack: Array(0...399))
        daily.append(makeRecord(dayKey: "2026-11-20", designCapacityMah: 0))

        let filtered30 = BatteryHealthTrendAnalysis.filtered(daily, range: .days30, now: now, calendar: calendar)
        let filtered90 = BatteryHealthTrendAnalysis.filtered(daily, range: .days90, now: now, calendar: calendar)
        let filteredYear = BatteryHealthTrendAnalysis.filtered(daily, range: .year1, now: now, calendar: calendar)
        let filteredAll = BatteryHealthTrendAnalysis.filtered(daily, range: .all, now: now, calendar: calendar)

        #expect(filtered30.count == 30)
        #expect(filtered90.count == 90)
        #expect(filteredYear.count == 365)
        #expect(filteredAll.count == 400)
        #expect(filtered30.first?.dayKey == "2026-10-26")
        #expect(filtered30.last?.dayKey == "2026-11-24")
        #expect(filteredAll.first?.dayKey == BatteryHealthRecord.dayKey(
            for: calendar.date(byAdding: .day, value: -399, to: now)!, calendar: calendar
        ))
    }

    @Test func trendAnalysisSummaryAndSingleDayBaseline() {
        let calendar = Self.utcCalendar

        // Empty summary
        let empty = BatteryHealthTrendAnalysis.summarize([], calendar: calendar)
        #expect(empty.recordCount == 0)
        #expect(empty.spanDays == 0)
        #expect(empty.startHealthPercent == nil)
        #expect(empty.healthDeltaPercent == nil)
        #expect(empty.capacityDeltaMah == nil)
        #expect(empty.cycleDelta == nil)

        // Single-day baseline: deltas must remain nil
        let single = makeRecord(
            dayKey: "2026-11-24",
            systemHealthPercent: 95,
            fullChargeCapacityMah: 4000,
            designCapacityMah: 4382,
            cycleCount: 150,
            designCycleCount: 1000
        )
        let singleSummary = BatteryHealthTrendAnalysis.summarize([single], calendar: calendar)
        #expect(singleSummary.recordCount == 1)
        #expect(singleSummary.spanDays == 0)
        #expect(singleSummary.startHealthPercent == 95)
        #expect(singleSummary.endHealthPercent == 95)
        #expect(singleSummary.healthDeltaPercent == nil)
        #expect(singleSummary.startCapacityMah == 4000)
        #expect(singleSummary.endCapacityMah == 4000)
        #expect(singleSummary.capacityDeltaMah == nil)
        #expect(singleSummary.startCycleCount == 150)
        #expect(singleSummary.endCycleCount == 150)
        #expect(singleSummary.cycleDelta == nil)
        #expect(singleSummary.designCapacityMah == 4382)
        #expect(singleSummary.designCycleCount == 1000)

        // Multi-day summary: systemHealthPercent never substituted with capacityRatioPercent
        let day1 = makeRecord(
            dayKey: "2026-10-01",
            systemHealthPercent: nil,
            fullChargeCapacityMah: 4150,
            designCapacityMah: 4382,
            cycleCount: 120,
            designCycleCount: 1000
        )
        let day2 = makeRecord(
            dayKey: "2026-10-15",
            systemHealthPercent: 97,
            fullChargeCapacityMah: 4100,
            designCapacityMah: 4382,
            cycleCount: 132,
            designCycleCount: nil
        )
        let day3 = makeRecord(
            dayKey: "2026-10-31",
            systemHealthPercent: 95,
            fullChargeCapacityMah: 4020,
            designCapacityMah: 4382,
            cycleCount: 145,
            designCycleCount: 1000
        )

        let multi = BatteryHealthTrendAnalysis.summarize([day3, day1, day2], calendar: calendar)
        #expect(multi.recordCount == 3)
        #expect(multi.spanDays == 30)
        #expect(multi.startHealthPercent == 97)
        #expect(multi.endHealthPercent == 95)
        #expect(multi.healthDeltaPercent == -2)
        #expect(multi.startCapacityMah == 4150)
        #expect(multi.endCapacityMah == 4020)
        #expect(multi.capacityDeltaMah == -130)
        #expect(multi.startCycleCount == 120)
        #expect(multi.endCycleCount == 145)
        #expect(multi.cycleDelta == 25)
        #expect(multi.designCapacityMah == 4382)
        #expect(multi.designCycleCount == 1000)

        // Only 1 official system health sample across 2 days -> healthDeltaPercent must be nil
        let partialHealth = BatteryHealthTrendAnalysis.summarize([day1, day2], calendar: calendar)
        #expect(partialHealth.startHealthPercent == 97)
        #expect(partialHealth.endHealthPercent == 97)
        #expect(partialHealth.healthDeltaPercent == nil)
        #expect(partialHealth.capacityDeltaMah == -50)
        #expect(partialHealth.cycleDelta == 12)
    }

    @Test func trendAnalysisYAxisDomains() {
        #expect(BatteryHealthTrendAnalysis.healthPercentDomain([]) == 80...100)
        #expect(BatteryHealthTrendAnalysis.capacityDomain([]) == 0...5_000)
        #expect(BatteryHealthTrendAnalysis.cycleDomain([]) == 0...50)

        // Single high point enforces minimum 10% span clamped within 0...100
        let highSingle = makeRecord(
            dayKey: "2026-11-24",
            systemHealthPercent: 98,
            fullChargeCapacityMah: 4300,
            nominalCapacityMah: 4320,
            designCapacityMah: 4382,
            cycleCount: 42
        )
        let highDomain = BatteryHealthTrendAnalysis.healthPercentDomain([highSingle])
        #expect(highDomain.lowerBound >= 0)
        #expect(highDomain.upperBound <= 100)
        #expect(highDomain.upperBound - highDomain.lowerBound >= 10)
        #expect(highDomain.contains(98))

        // Low boundary clamps within 0...100 with >= 10% span
        let lowSingle = makeRecord(
            dayKey: "2026-11-24",
            systemHealthPercent: 2,
            fullChargeCapacityMah: nil,
            nominalCapacityMah: nil,
            designCapacityMah: 4382,
            cycleCount: 0
        )
        let lowDomain = BatteryHealthTrendAnalysis.healthPercentDomain([lowSingle])
        #expect(lowDomain == 0...10)

        // Covers both systemHealthPercent and capacityRatioPercent
        let mixed = makeRecord(
            dayKey: "2026-11-24",
            systemHealthPercent: 96,
            fullChargeCapacityMah: 3800,
            designCapacityMah: 4382,
            cycleCount: 200
        )
        let mixedDomain = BatteryHealthTrendAnalysis.healthPercentDomain([mixed])
        #expect(mixedDomain.contains(96))
        #expect(mixedDomain.contains(mixed.capacityRatioPercent!))
        #expect(mixedDomain.lowerBound <= 83)
        #expect(mixedDomain.upperBound >= 99)

        // Capacity domain covers FCC and designCapacityMah with breathing room and lower >= 0
        let capDomain = BatteryHealthTrendAnalysis.capacityDomain([mixed])
        #expect(capDomain.lowerBound >= 0)
        #expect(capDomain.lowerBound < 3800)
        #expect(capDomain.upperBound > 4382)

        let tinyCap = makeRecord(
            dayKey: "2026-11-24",
            fullChargeCapacityMah: 100,
            nominalCapacityMah: 110,
            designCapacityMah: 120,
            cycleCount: 0
        )
        #expect(BatteryHealthTrendAnalysis.capacityDomain([tinyCap]).lowerBound == 0)

        // Cycle domain covers cycle range with padding and lower >= 0
        let c1 = makeRecord(dayKey: "2026-11-01", cycleCount: 40)
        let c2 = makeRecord(dayKey: "2026-11-24", cycleCount: 55)
        let cycleDomain = BatteryHealthTrendAnalysis.cycleDomain([c1, c2])
        #expect(cycleDomain.lowerBound >= 0)
        #expect(cycleDomain.lowerBound < 40)
        #expect(cycleDomain.upperBound > 55)
        #expect(BatteryHealthTrendAnalysis.cycleDomain([tinyCap]).lowerBound == 0)
        #expect(BatteryHealthTrendAnalysis.cycleDomain([tinyCap]).upperBound >= 10)
    }

    @Test @MainActor func dataStoreAndPowerSamplerHealthHistoryIntegration() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = DataStore(directory: dir)
        let sampleDate = makeDate(year: 2026, month: 11, day: 24, hour: 10)
        store.recordHealthSample(
            date: sampleDate,
            systemHealthPercent: 95,
            fullChargeCapacityMah: 3992,
            nominalCapacityMah: 4122,
            designCapacityMah: 4382,
            cycleCount: 173,
            designCycleCount: 1000,
            temperatureC: 31.2
        )
        store.flushPendingWritesForTesting()

        let stored = store.healthHistory()
        #expect(stored.count == 1)
        #expect(stored[0].systemHealthPercent == 95)
        #expect(stored[0].fullChargeCapacityMah == 3992)
        #expect(stored[0].nominalCapacityMah == 4122)
        #expect(stored[0].designCapacityMah == 4382)
        #expect(stored[0].cycleCount == 173)
        #expect(stored[0].designCycleCount == 1000)

        // Reloading DataStore preserves permanent health ledger
        let reloadedStore = DataStore(directory: dir)
        #expect(reloadedStore.healthHistory() == stored)

        // PowerSampler pre-loads health history on init
        let sampler = PowerSampler(dataStore: reloadedStore)
        #expect(sampler.healthHistory == stored)
        sampler.stop()
    }

    @Test @MainActor func crossMidnightStaleSystemHealthIsNeverWrittenToNextDay() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Self.utcCalendar
        let store = BatteryHealthStore(directory: dir)

        let day1ReadAt = makeDate(year: 2026, month: 11, day: 23, hour: 23, minute: 30, calendar: calendar)
        let day2Early = makeDate(year: 2026, month: 11, day: 24, hour: 0, minute: 5, calendar: calendar)
        let day2Fresh = makeDate(year: 2026, month: 11, day: 24, hour: 1, minute: 0, calendar: calendar)

        // Day 1 stores its same-day system health + read timestamp
        #expect(store.record(
            date: day1ReadAt,
            systemHealthPercent: 95,
            systemHealthReadAt: day1ReadAt,
            fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120,
            designCapacityMah: 4382,
            cycleCount: 170,
            designCycleCount: 1000,
            temperatureC: 31.0,
            calendar: calendar
        ))

        // Cross-midnight write carrying yesterday's cached systemHealthReadAt must NOT populate Day 2 systemHealthPercent
        #expect(store.record(
            date: day2Early,
            systemHealthPercent: 95,
            systemHealthReadAt: day1ReadAt,
            fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120,
            designCapacityMah: 4382,
            cycleCount: 170,
            designCycleCount: 1000,
            temperatureC: 30.5,
            calendar: calendar
        ))

        let afterMidnight = store.allRecords()
        #expect(afterMidnight.map(\.dayKey) == ["2026-11-23", "2026-11-24"])
        #expect(afterMidnight[0].systemHealthPercent == 95)
        #expect(afterMidnight[0].systemHealthReadAt == day1ReadAt)
        #expect(afterMidnight[1].systemHealthPercent == nil)
        #expect(afterMidnight[1].systemHealthReadAt == nil)

        // Fresh Day 2 system_profiler reading updates Day 2 and is preserved on subsequent stale/nil writes
        #expect(store.record(
            date: day2Fresh,
            systemHealthPercent: 94,
            systemHealthReadAt: day2Fresh,
            fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120,
            designCapacityMah: 4382,
            cycleCount: 170,
            designCycleCount: 1000,
            temperatureC: 30.5,
            calendar: calendar
        ))
        _ = store.record(
            date: day2Fresh.addingTimeInterval(300),
            systemHealthPercent: 95,
            systemHealthReadAt: day1ReadAt,
            fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120,
            designCapacityMah: 4382,
            cycleCount: 171,
            designCycleCount: 1000,
            temperatureC: 30.5,
            calendar: calendar
        )
        let finalRecords = store.allRecords()
        #expect(finalRecords[1].systemHealthPercent == 94)
        #expect(finalRecords[1].systemHealthReadAt == day2Fresh)

        // PowerSampler guard: yesterday's applySystemHealth must not leak into today's recordHealthTelemetry
        let samplerDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: samplerDir) }
        let dataStore = DataStore(directory: samplerDir)
        let sampler = PowerSampler(dataStore: dataStore)
        defer { sampler.stop() }

        let localCal = Calendar.current
        let todayNoon = localCal.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        let yesterdayLate = localCal.date(byAdding: .day, value: -1, to: todayNoon)!
        let info = BatteryInfo(
            designCapacity: 4382, maxCapacity: 3992, cycleCount: 173,
            voltage: 11500, instantAmperage: -500, temperature: 31,
            isCharging: false, externalConnected: false, chargeStatus: nil,
            systemPower: 10, batteryPower: 10, batteryPowerAvailable: true,
            adapterInputPower: 0, adapterInputPowerAvailable: false,
            systemPowerAvailable: true, systemPowerIsEstimated: false,
            adapterWatts: 0, adapterProtocol: "未连接",
            nominalCapacity: 4122, designCycleCount: 1000, maxCapacityIsEstimated: false
        )
        sampler.applySystemHealth(SystemHealthReading(percent: 96, readAt: yesterdayLate))
        sampler.recordHealthTelemetry(info: info, at: todayNoon)
        dataStore.flushPendingWritesForTesting()

        let todayKey = BatteryHealthRecord.dayKey(for: todayNoon, calendar: localCal)
        let todayRecord = dataStore.healthHistory().first { $0.dayKey == todayKey }
        #expect(todayRecord != nil)
        #expect(todayRecord?.systemHealthPercent == nil)
        #expect(todayRecord?.systemHealthReadAt == nil)
    }

    @Test @MainActor func estimatedFullChargeCapacityExcludedFromHealthStoreAndDiscountedInEstimator() throws {
        // BatteryReader provenance distinction
        let directFCC = BatteryReader.resolvedFullChargeCapacityInfo(fcc: 3992, rawMax: 91, design: 4382)
        #expect(directFCC.capacity == 3992 && !directFCC.isEstimated)
        let legacyMah = BatteryReader.resolvedFullChargeCapacityInfo(fcc: 0, rawMax: 4100, design: 4382)
        #expect(legacyMah.capacity == 4100 && !legacyMah.isEstimated)
        let fallbackPct = BatteryReader.resolvedFullChargeCapacityInfo(fcc: 0, rawMax: 92, design: 4382)
        #expect(fallbackPct.capacity == 4382 * 92 / 100 && fallbackPct.isEstimated)
        #expect(BatteryReader.resolvedFullChargeCapacity(fcc: 0, rawMax: 92, design: 4382) == fallbackPct.capacity)

        // PowerSampler must exclude estimated maxCapacity from permanent mAh health ledger
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = DataStore(directory: dir)
        let sampler = PowerSampler(dataStore: store)
        defer { sampler.stop() }

        let sampleDate = Date()
        let estimatedInfo = BatteryInfo(
            designCapacity: 4382, maxCapacity: fallbackPct.capacity, cycleCount: 173,
            voltage: 11500, instantAmperage: -500, temperature: 31,
            isCharging: false, externalConnected: false, chargeStatus: nil,
            systemPower: 10, batteryPower: 10, batteryPowerAvailable: true,
            adapterInputPower: 0, adapterInputPowerAvailable: false,
            systemPowerAvailable: true, systemPowerIsEstimated: false,
            adapterWatts: 0, adapterProtocol: "未连接",
            nominalCapacity: 4122, designCycleCount: 1000, maxCapacityIsEstimated: true
        )
        sampler.recordHealthTelemetry(info: estimatedInfo, at: sampleDate)
        store.flushPendingWritesForTesting()
        #expect(store.healthHistory().count == 1)
        #expect(store.healthHistory()[0].fullChargeCapacityMah == nil)

        let directInfo = BatteryInfo(
            designCapacity: 4382, maxCapacity: 3992, cycleCount: 173,
            voltage: 11500, instantAmperage: -500, temperature: 31,
            isCharging: false, externalConnected: false, chargeStatus: nil,
            systemPower: 10, batteryPower: 10, batteryPowerAvailable: true,
            adapterInputPower: 0, adapterInputPowerAvailable: false,
            systemPowerAvailable: true, systemPowerIsEstimated: false,
            adapterWatts: 0, adapterProtocol: "未连接",
            nominalCapacity: 4122, designCycleCount: 1000, maxCapacityIsEstimated: false
        )
        sampler.recordHealthTelemetry(info: directInfo, at: sampleDate.addingTimeInterval(10))
        store.flushPendingWritesForTesting()
        #expect(store.healthHistory()[0].fullChargeCapacityMah == 3992)

        // RuntimeEstimator applies conservative 0.85 confidence discount when fullChargeCapacityIsEstimated is true
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let aggregates: [MinuteAggregate] = (1...15).reversed().map { minutesBack in
            MinuteAggregate(
                windowStart: now.addingTimeInterval(-Double(minutesBack) * 60),
                systemEnergyWh: 0.2,
                systemPowerAverage: 12,
                systemPowerPeak: 14,
                systemCoverage: 1,
                batteryChargeSeconds: 0,
                batteryDischargeWh: 0.2,
                batteryDischargeSeconds: 60,
                temperatureAverage: 32,
                temperatureMaximum: 33,
                temperatureCoverage: 1
            )
        }
        var directInput = RuntimeEstimator.Inputs()
        directInput.now = now
        directInput.currentLevel = 70
        directInput.externalConnected = false
        directInput.isCharging = false
        directInput.minuteAggregates = aggregates
        directInput.fullChargeCapacityMah = 4000
        directInput.fullChargeCapacityIsEstimated = false
        directInput.voltageMV = 11_500

        var estimatedInput = directInput
        estimatedInput.fullChargeCapacityIsEstimated = true

        let directEvidence = try #require(RuntimeEstimator.batteryPowerEvidence(directInput))
        let estimatedEvidence = try #require(RuntimeEstimator.batteryPowerEvidence(estimatedInput))
        #expect(estimatedEvidence.confidence < directEvidence.confidence)
        #expect(abs(estimatedEvidence.confidence - directEvidence.confidence * 0.85) < 1e-9)
    }

    @Test func subThresholdDailyPeakTemperatureVisibleImmediatelyAndPersistedOnFlush() throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let calendar = Self.utcCalendar
        let store = BatteryHealthStore(directory: dir)
        let day = makeDate(year: 2026, month: 9, day: 1, hour: 10, calendar: calendar)

        func lineCount() throws -> Int {
            try String(contentsOf: store.fileURL, encoding: .utf8)
                .split(separator: "\n")
                .count
        }

        // Initial baseline at 40.0°C writes to disk
        #expect(store.record(
            date: day, systemHealthPercent: 95, fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120, designCapacityMah: 4382, cycleCount: 150,
            designCycleCount: 1000, temperatureC: 40.0, calendar: calendar
        ))
        #expect(try lineCount() == 1)

        // Sub-threshold +0.49°C peak does not immediately write to disk, yet allRecords() reflects 40.49°C right away
        #expect(!store.record(
            date: day.addingTimeInterval(60), systemHealthPercent: 95, fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120, designCapacityMah: 4382, cycleCount: 150,
            designCycleCount: 1000, temperatureC: 40.49, calendar: calendar
        ))
        #expect(try lineCount() == 1)
        #expect(store.allRecords()[0].peakTemperatureC == 40.49)

        // Cooler follow-up reading never lowers the in-memory peak
        #expect(!store.record(
            date: day.addingTimeInterval(120), systemHealthPercent: 95, fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120, designCapacityMah: 4382, cycleCount: 150,
            designCycleCount: 1000, temperatureC: 37.5, calendar: calendar
        ))
        #expect(store.allRecords()[0].peakTemperatureC == 40.49)

        // flushPending() persists the 40.49°C peak to disk and is idempotent on repeat calls
        store.flushPending()
        #expect(try lineCount() == 2)
        store.flushPending()
        #expect(try lineCount() == 2)

        let reloaded = BatteryHealthStore(directory: dir)
        #expect(reloaded.allRecords().count == 1)
        #expect(reloaded.allRecords()[0].peakTemperatureC == 40.49)

        // DataStore.flushNow() also flushes debounced peaks before app termination
        let dsDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dsDir) }
        let ds = DataStore(directory: dsDir)
        ds.recordHealthSample(
            date: day, systemHealthPercent: 95, fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120, designCapacityMah: 4382, cycleCount: 150,
            designCycleCount: 1000, temperatureC: 40.0
        )
        ds.recordHealthSample(
            date: day.addingTimeInterval(60), systemHealthPercent: 95, fullChargeCapacityMah: 4000,
            nominalCapacityMah: 4120, designCapacityMah: 4382, cycleCount: 150,
            designCycleCount: 1000, temperatureC: 40.49
        )
        ds.flushNow()
        let reloadedDS = DataStore(directory: dsDir)
        #expect(reloadedDS.healthHistory().first?.peakTemperatureC == 40.49)
    }
}
