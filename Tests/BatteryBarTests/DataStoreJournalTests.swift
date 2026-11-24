import Testing
import Foundation
@testable import BatteryBar

/// snapshots.jsonl 纯本地追加日志：迁移、追加、坏行容忍、24 小时保留与低频 compact。
/// 全部使用注入的临时目录，不触碰用户真实数据。
@Suite struct DataStoreJournalTests {

    private func makeStore() throws -> (dir: URL, journal: URL, legacy: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("BatteryBarJournalTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir,
                dir.appendingPathComponent("snapshots.jsonl"),
                dir.appendingPathComponent("snapshots.json"))
    }

    private func cleanUp(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    private func snap(_ minutesAgo: Double, level: Double = 50, charging: Bool = false) -> BatterySnapshot {
        BatterySnapshot(
            timestamp: Date().addingTimeInterval(-minutesAgo * 60),
            level: level, isCharging: charging, wattage: 5.5
        )
    }

    @Test func legacyArrayMigratesToJournalWithoutDeletion() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let legacySnaps = [snap(120), snap(60), snap(10)]
        try JSONEncoder().encode(legacySnaps).write(to: ctx.legacy)

        let store = DataStore(directory: ctx.dir)
        store.flushPendingWritesForTesting()

        #expect(store.allSnapshots().count == 3)
        #expect(FileManager.default.fileExists(atPath: ctx.journal.path))
        #expect(FileManager.default.fileExists(atPath: ctx.legacy.path))
        let lines = try String(contentsOf: ctx.journal, encoding: .utf8)
            .split(separator: "\n")
        #expect(lines.count == 3)
        for line in lines {
            _ = try JSONDecoder().decode(BatterySnapshot.self, from: Data(line.utf8))
        }
    }

    @Test func saveAppendsSingleLineInsteadOfRewrite() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        store.saveSnapshot(snap(2))
        store.flushPendingWritesForTesting()
        #expect(try String(contentsOf: ctx.journal, encoding: .utf8).split(separator: "\n").count == 1)

        store.saveSnapshot(snap(1))
        store.flushPendingWritesForTesting()

        let text = try String(contentsOf: ctx.journal, encoding: .utf8)
        #expect(text.split(separator: "\n").count == 2)
        #expect(store.allSnapshots().count == 2)
    }

    @Test func corruptTailLineSkippedOthersLoaded() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        let a = snap(30), b = snap(20), c = snap(10)
        store.saveSnapshot(a); store.saveSnapshot(b); store.saveSnapshot(c)
        store.flushPendingWritesForTesting()

        let handle = try FileHandle(forWritingTo: ctx.journal)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{\"id\":\"half-written".utf8))
        try handle.close()

        let reloaded = DataStore(directory: ctx.dir)
        #expect(reloaded.allSnapshots().count == 3)
    }

    @Test func corruptMiddleLineSkippedHistoryStillLoads() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        let a = snap(30), b = snap(20), c = snap(10)
        store.saveSnapshot(a); store.saveSnapshot(b); store.saveSnapshot(c)
        store.flushPendingWritesForTesting()

        let raw = try String(contentsOf: ctx.journal, encoding: .utf8)
        let lines = raw.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 3 else {
            Issue.record("journal unexpectedly short: \(lines.count)")
            return
        }
        let corrupted = [lines[0], "{broken", lines[1], lines[2]].joined(separator: "\n") + "\n"
        try corrupted.write(to: ctx.journal, atomically: true, encoding: .utf8)

        let reloaded = DataStore(directory: ctx.dir)
        #expect(reloaded.allSnapshots().count == 3)
    }

    @Test func retentionTrimsBeyond24hOnLoadAndSave() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let old = BatterySnapshot(timestamp: Date().addingTimeInterval(-48 * 3600), level: 90, isCharging: false, wattage: 5)
        let fresh = BatterySnapshot(timestamp: Date(), level: 50, isCharging: false, wattage: 5)
        try JSONEncoder().encode([old, fresh]).write(to: ctx.legacy)

        let store = DataStore(directory: ctx.dir)
        store.flushPendingWritesForTesting()
        #expect(store.allSnapshots().count == 1)
        #expect(store.allSnapshots().first?.id == fresh.id)
    }

    @Test func emptyJournalFallsBackToLegacy() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let snaps = [snap(30), snap(20)]
        try JSONEncoder().encode(snaps).write(to: ctx.legacy)
        try Data("".utf8).write(to: ctx.journal)

        let store = DataStore(directory: ctx.dir)
        store.flushPendingWritesForTesting()
        #expect(store.allSnapshots().count == 2)
        let lines = try String(contentsOf: ctx.journal, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
    }

    @Test func migratedV2LinesKeepUnknownPowerSource() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let recentTS = Date().addingTimeInterval(-600).timeIntervalSinceReferenceDate
        let v2Line = "{\"id\":\"\(UUID().uuidString)\",\"timestamp\":\(recentTS),\"level\":100,\"isCharging\":false,\"wattage\":2.1,\"batteryPower\":2.1,\"systemPowerAvailable\":true,\"systemPowerIsEstimated\":true,\"temperature\":31.0,\"screenOn\":true,\"dirty\":false}"
        try Data(v2Line.utf8).write(to: ctx.journal)

        let store = DataStore(directory: ctx.dir)
        store.flushPendingWritesForTesting()
        let loaded = store.allSnapshots()
        #expect(loaded.count == 1)
        #expect(loaded[0].externalConnected == nil)
        #expect(loaded[0].trustedSystemLoad == nil)
    }

    @Test func steadyStateExpirationCompactsOnlyAfterThreshold() throws {
        let ctx = try makeStore()
        defer { cleanUp(ctx.dir) }
        let store = DataStore(directory: ctx.dir)
        let base = Date()

        for i in 0..<60 {
            store.saveSnapshot(BatterySnapshot(
                timestamp: base.addingTimeInterval(TimeInterval(i * 60)),
                level: 50, isCharging: false, wattage: 5))
        }
        store.flushPendingWritesForTesting()
        #expect(try String(contentsOf: ctx.journal, encoding: .utf8).split(separator: "\n").count == 60)

        for k in 1...10 {
            store.saveSnapshot(BatterySnapshot(
                timestamp: base.addingTimeInterval(24 * 3600 + TimeInterval(k * 60)),
                level: 50, isCharging: false, wattage: 5))
            store.flushPendingWritesForTesting()
        }

        #expect(store.allSnapshots().count == 60)
        let midLines = try String(contentsOf: ctx.journal, encoding: .utf8).split(separator: "\n")
        #expect(midLines.count == 70)

        for k in 11...62 {
            store.saveSnapshot(BatterySnapshot(
                timestamp: base.addingTimeInterval(24 * 3600 + TimeInterval(k * 60)),
                level: 50, isCharging: false, wattage: 5))
        }
        store.flushPendingWritesForTesting()

        let endLines = try String(contentsOf: ctx.journal, encoding: .utf8).split(separator: "\n")
        #expect(endLines.count == store.allSnapshots().count)
        let lastNow = base.addingTimeInterval(24 * 3600 + TimeInterval(62 * 60))
        for line in endLines {
            let s = try JSONDecoder().decode(BatterySnapshot.self, from: Data(line.utf8))
            #expect(s.timestamp >= lastNow.addingTimeInterval(-24 * 3600))
        }
    }
}
