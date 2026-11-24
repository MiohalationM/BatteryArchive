import Foundation
import Testing
@testable import BatteryBar

@Suite struct AuditRegressionTests {
    private let now = Date(timeIntervalSince1970: 1_793_200_000)

    private func snapshot(_ minute: Int, _ level: Double, external: Bool? = false, charging: Bool = false) -> BatterySnapshot {
        BatterySnapshot(timestamp: now.addingTimeInterval(Double(minute) * 60), level: level,
                        isCharging: charging, wattage: 8,
                        externalConnected: external)
    }

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("BatteryAudit-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test func dischargeUsesOnlyLatestContinuousEpisode() throws {
        var input = RuntimeEstimator.Inputs()
        input.now = now
        input.currentLevel = 84.2
        input.externalConnected = false
        input.snapshots = (-60 ... -31).map { snapshot($0, 90 - Double($0 + 60) * 0.2) }
        input.snapshots += (-30 ... -25).map { snapshot($0, 84 + Double($0 + 30), external: true, charging: true) }
        input.snapshots += (-24 ... 0).map { snapshot($0, 89 - Double($0 + 24) * 0.2) }
        let result = try #require(RuntimeEstimator.dischargeEstimate(input))
        #expect(abs(result.ratePercentPerHour - 12) < 0.001)
        #expect(abs(result.valueHours - 84.2 / 12) < 0.001)
    }

    @Test func oldDischargeOrChargingCannotResumeAcrossPause() {
        var input = RuntimeEstimator.Inputs()
        input.now = now
        input.currentLevel = 82
        input.externalConnected = false
        input.snapshots = (-50 ... -10).map { snapshot($0, 90 - Double($0 + 50) * 0.2) }
        input.snapshots += (-9 ... -1).map { snapshot($0, 82, external: true) }
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
        input.externalConnected = true
        input.isCharging = true
        input.currentLevel = 70
        input.chargeTargetPercent = 80
        input.snapshots = (-30 ... -10).map { snapshot($0, 60 + Double($0 + 30) * 0.5, external: true, charging: true) }
        input.snapshots += (-9 ... -1).map { snapshot($0, 70, external: true) }
        #expect(RuntimeEstimator.chargeEstimate(input) == nil)
    }

    @Test func liveTransitionCutsHistoryEvenBetweenMinuteSnapshots() {
        var input = RuntimeEstimator.Inputs()
        input.now = now
        input.currentLevel = 70
        input.externalConnected = false
        input.snapshots = (-45 ... -1).map { snapshot($0, 80 - Double($0 + 45) * 0.2) }
        #expect(RuntimeEstimator.dischargeEstimate(input) != nil)
        input.stateObservedSince = now.addingTimeInterval(-30)
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
        input.stateObservedSince = nil
        input.now = now.addingTimeInterval(300)
        #expect(RuntimeEstimator.dischargeEstimate(input) == nil)
    }

    @Test func journalTailCannotSwallowNextRecord() throws {
        for tail in ["", "\n{\"unfinished\":"] {
            let dir = try directory()
            defer { try? FileManager.default.removeItem(at: dir) }
            var first = snapshot(0, 60)
            first.timestamp = Date().addingTimeInterval(-60)
            var bytes = try JSONEncoder().encode(first)
            bytes.append(contentsOf: tail.utf8)
            try bytes.write(to: dir.appendingPathComponent("snapshots.jsonl"))
            let store = DataStore(directory: dir)
            var next = first
            next.id = UUID()
            next.timestamp = Date()
            store.saveSnapshot(next)
            store.flushNow()
            let reloaded = DataStore(directory: dir)
            #expect(Set(reloaded.allSnapshots().map(\.id)) == [first.id, next.id])
        }
    }

    @Test func oneBadDailyCheckpointDoesNotBlockOtherDays() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let daily = dir.appendingPathComponent("usage-daily")
        try FileManager.default.createDirectory(at: daily, withIntermediateDirectories: true)
        let bad = daily.appendingPathComponent("bad.json")
        try Data("{broken".utf8).write(to: bad)
        let history = UsageHistoryStore(directory: dir, now: now)
        let bucket = UsageBucket(measurementEpoch: history.measurementEpoch, runID: UUID(), timeZoneID: "UTC",
                                 start: now.addingTimeInterval(-60), end: now,
                                 onPowerSeconds: 60)
        history.append([bucket], now: now)
        #expect(history.dailySummaries().count == 1)
        #expect(history.dailySummaries().first?.onPowerSeconds == 60)
        let reloaded = UsageHistoryStore(directory: dir, now: now)
        #expect(reloaded.dailySummaries() == history.dailySummaries())
        #expect(reloaded.read(in: DateInterval(start: bucket.start, end: now), now: now).error != nil)
        #expect(try String(contentsOf: bad, encoding: .utf8) == "{broken")
    }

    @Test func missingCapacityCannotBecomeHundredPercent() {
        #expect(BatteryReader.resolvedFullChargeCapacity(fcc: 0, rawMax: nil, design: 5000) == 0)
        #expect(BatteryReader.resolvedFullChargeCapacity(fcc: 0, rawMax: 100, design: 5000) == 5000)
        #expect(BatteryReader.resolvedFullChargeCapacity(fcc: 4800, rawMax: nil, design: 5000) == 4800)
        #expect(BatteryReader.resolvedFullChargeCapacity(fcc: 0, rawMax: 4500, design: 5000) == 4500)
        #expect(BatteryReader.resolvedFullChargeCapacity(fcc: 0, rawMax: 101, design: 5000) == 0)
    }
}
