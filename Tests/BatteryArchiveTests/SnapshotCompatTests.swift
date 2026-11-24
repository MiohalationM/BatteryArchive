import Testing
import Foundation
@testable import BatteryArchive

/// BatterySnapshot v1/v2/v3/v5 本地兼容、电源来源 provenance 与功率口径测试。
///
/// 关键不变量：
/// - isCharging 只表达电池包是否充入；externalConnected 缺失 = 来源未知，
///   不得用 !isCharging 推断离电；
/// - 估算负载只在明确离电（externalConnected == false）时可信；
///   实测遥测（estimated == false）独立可信；
/// - "接电未充电被误标为可用离电负载"的污染点（level>=99、!charging、
///   estimated=true、无 externalConnected）必须被 trustedSystemLoad 排除。
@Suite struct SnapshotCompatTests {

    private let base = Date(timeIntervalSince1970: 1_720_780_800)

    // MARK: - v1 JSON 解码（无新字段 → 来源未知）

    @Test func v1ChargingSnapshotExcludedFromSystemLoad() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":80,"isCharging":true,
         "wattage":28.5,"temperature":31.0,"screenOn":true,"cpuPower":0,"gpuPower":0}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.isCharging)
        #expect(snap.systemPowerAvailable == false)      // 充电功率不能冒充系统负载
        #expect(snap.trustedSystemLoad == nil)
        #expect(snap.externalConnected == nil)           // v1 无电源字段，未知
    }

    @Test func v1DischargingSnapshotUnknownSourceExcluded() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":60,"isCharging":false,
         "wattage":8.4,"temperature":30.0,"screenOn":true}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.systemPowerAvailable == true)
        #expect(snap.systemPowerIsEstimated == true)
        #expect(snap.externalConnected == nil)
        #expect(snap.trustedSystemLoad == nil)           // 来源未知 + 估算 → 排除
    }

    // MARK: - 核心反例：接电未充电（满电/充电上限）

    @Test func legacyPluggedNotChargingPollutionRejected() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":100,"isCharging":false,
         "wattage":2.1,"batteryPower":2.1,"systemPowerAvailable":true,"systemPowerIsEstimated":true,
         "temperature":31.0,"screenOn":true}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.systemPowerAvailable == true)
        #expect(snap.trustedSystemLoad == nil)           // 来源未知 + 估算 → 排除
        #expect(snap.externalConnected == nil)
    }

    @Test func explicitExternalConnectedDrivesTrust() {
        let paused = BatterySnapshot(timestamp: base, level: 100, isCharging: false,
                                     wattage: 2.0, systemPowerAvailable: true,
                                     systemPowerIsEstimated: true, externalConnected: true)
        #expect(paused.trustedSystemLoad == nil)

        let onBattery = BatterySnapshot(timestamp: base, level: 70, isCharging: false,
                                        wattage: 8.5, systemPowerAvailable: true,
                                        systemPowerIsEstimated: true, externalConnected: false)
        #expect(onBattery.trustedSystemLoad == 8.5)

        // 实测遥测独立可信：即使电源状态是接电未充电也保留
        let telemetryPaused = BatterySnapshot(timestamp: base, level: 100, isCharging: false,
                                              wattage: 12.3, systemPowerAvailable: true,
                                              systemPowerIsEstimated: false, externalConnected: true)
        #expect(telemetryPaused.trustedSystemLoad == 12.3)

        // 遥测但来源字段缺失（v2 实测点）：按其独立可信标记保留
        let telemetryUnknownSource = BatterySnapshot(timestamp: base, level: 100, isCharging: false,
                                                     wattage: 11.8, systemPowerAvailable: true,
                                                     systemPowerIsEstimated: false, externalConnected: nil)
        #expect(telemetryUnknownSource.trustedSystemLoad == 11.8)
    }

    // MARK: - v2/v3 编解码往返

    @Test func v2CodableRoundTrip() throws {
        let snap = BatterySnapshot(
            timestamp: base,
            level: 42,
            isCharging: false,
            wattage: 9.1,
            systemPowerAvailable: true,
            systemPowerIsEstimated: false
        )
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
        #expect(decoded.externalConnected == nil)        // 未设置 → 键缺失 → 解回 nil
    }

    @Test func v3CodableRoundTripKeepsExternalConnected() throws {
        for ext in [true, false] {
            let snap = BatterySnapshot(timestamp: base, level: 55, isCharging: false,
                                       wattage: 10, externalConnected: ext)
            let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(snap))
            #expect(decoded.externalConnected == ext)
            #expect(decoded == snap)
        }
    }

    @Test func memberwiseDefaultsDeriveFromChargingState() {
        let charging = BatterySnapshot(timestamp: base, level: 90, isCharging: true, wattage: 30)
        #expect(charging.systemPowerAvailable == false)
        #expect(charging.externalConnected == nil)

        let discharging = BatterySnapshot(timestamp: base, level: 90, isCharging: false, wattage: 6)
        #expect(discharging.systemPowerAvailable == true)
        #expect(discharging.systemPowerIsEstimated == true)

        let explicit = BatterySnapshot(timestamp: base, level: 90, isCharging: false, wattage: 13.8,
                                       systemPowerAvailable: true, systemPowerIsEstimated: false,
                                       externalConnected: true)
        #expect(explicit.systemPowerIsEstimated == false)
        #expect(explicit.trustedSystemLoad == 13.8)      // 遥测不受电源状态影响
    }
}

/// BatterySnapshot v5：分钟聚合字段与 v1–v4 兼容。
@Suite struct SnapshotV5CompatTests {

    private let base = Date(timeIntervalSince1970: 1_720_780_800)
    private let windowStart = Date(timeIntervalSince1970: 1_800_000_000)

    /// 旧 v4 JSON（无任何 v5 键）必须无损解码，v5 字段全部为 nil
    @Test func v4JSONDecodesWithAllV5FieldsNil() throws {
        let json = """
        {"id":"\(UUID().uuidString)","timestamp":1720780800.0,"level":80,"isCharging":false,
         "wattage":9.5,"temperature":31.0,"screenOn":true,"externalConnected":false,
         "lowPowerModeEnabled":true,"thermalState":"正常"}
        """.data(using: .utf8)!
        let snap = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(snap.aggregateWindowStart == nil)
        #expect(snap.systemEnergyWh == nil)
        #expect(snap.systemPowerAverage == nil)
        #expect(snap.temperatureAverage == nil)
        #expect(snap.trustedSystemLoad == 9.5)
    }

    @Test func v5CodableRoundTrip() throws {
        var snap = BatterySnapshot(
            timestamp: base, level: 55, isCharging: false, wattage: 11,
            externalConnected: false
        )
        snap.apply(
            minuteAggregate: MinuteAggregate(
                windowStart: windowStart,
                systemEnergyWh: 0.15,
                systemPowerAverage: 9,
                systemPowerPeak: 12.5,
                systemCoverage: 1,
                batteryChargeSeconds: 0,
                batteryDischargeWh: 0.15,
                batteryDischargeSeconds: 60,
                temperatureAverage: 29.5,
                temperatureMaximum: 31,
                temperatureCoverage: 1
            )
        )
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: JSONEncoder().encode(snap))
        #expect(decoded == snap)
    }

    /// 聚合写入按覆盖率门控：<0.8 不产生完整分钟指标；<0.5 温度趋势留空但最大值与覆盖率如实记录。
    @Test func aggregateApplyGatesByFrozenCoverageThresholds() {
        func make(_ systemCoverage: Double, _ tempCoverage: Double) -> MinuteAggregate {
            MinuteAggregate(
                windowStart: windowStart,
                systemEnergyWh: 0.1666,
                systemPowerAverage: 10,
                systemPowerPeak: 14,
                systemCoverage: systemCoverage,
                batteryChargeSeconds: 30,
                batteryDischargeWh: 0.05,
                batteryDischargeSeconds: 20,
                temperatureAverage: 30,
                temperatureMaximum: 33,
                temperatureCoverage: tempCoverage
            )
        }

        var sparse = BatterySnapshot(
            timestamp: base, level: 50, isCharging: false, wattage: 3,
            externalConnected: false
        )
        sparse.apply(minuteAggregate: make(0.4, 0.3))
        #expect(sparse.systemEnergyWh == nil)
        #expect(sparse.systemPowerAverage == nil)
        #expect(sparse.systemPowerPeak == nil)
        // coverage<0.5：均值不可用于趋势，但该分钟确实观察到温度 → 最大值必须保留
        #expect(sparse.temperatureAverage == nil)
        #expect(sparse.temperatureMaximum == 33)
        #expect(sparse.systemCoverage == 0.4)
        #expect(sparse.temperatureCoverage == 0.3)

        var full = BatterySnapshot(
            timestamp: base, level: 50, isCharging: false, wattage: 10,
            externalConnected: false
        )
        full.apply(minuteAggregate: make(1.0, 0.9))
        #expect(full.systemEnergyWh == 0.1666)
        #expect(full.systemPowerAverage == 10)
        #expect(full.temperatureAverage == 30)
        #expect(full.temperatureMaximum == 33)
    }
}

/// 快照保留窗口：24 小时裁剪、未来异常点拒绝、硬上限。
@Suite struct RetentionPolicyTests {
    private func makeSnaps(_ agesHours: [Double], now: Date) -> [BatterySnapshot] {
        agesHours.map { BatterySnapshot(timestamp: now.addingTimeInterval($0 * 3600), level: 50, isCharging: false, wattage: 5) }
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func olderThan24hDropped() {
        let snaps = makeSnaps([-30, -25, -10, -1], now: now)
        let retained = DataStore.retainedSnapshots(snaps, now: now)
        #expect(retained.count == 2)
        #expect(retained.allSatisfy { $0.timestamp >= now.addingTimeInterval(-24 * 3600) })
    }

    @Test func futureOutliersRejected() {
        var snaps = makeSnaps([-2, -1], now: now)
        snaps.append(BatterySnapshot(timestamp: now.addingTimeInterval(3600), level: 50, isCharging: false, wattage: 5))
        let retained = DataStore.retainedSnapshots(snaps, now: now)
        #expect(retained.count == 2)
    }

    @Test func smallClockSkewTolerated() {
        let skewed = [BatterySnapshot(timestamp: now.addingTimeInterval(120), level: 50, isCharging: false, wattage: 5)]
        #expect(DataStore.retainedSnapshots(skewed, now: now).count == 1)
    }

    @Test func hardCapTrimsOldest() {
        var snaps: [BatterySnapshot] = []
        for i in 0..<2000 {
            snaps.append(BatterySnapshot(
                timestamp: now.addingTimeInterval(TimeInterval(-i)),
                level: 50, isCharging: false, wattage: 5
            ))
        }
        let retained = DataStore.retainedSnapshots(snaps, now: now, hours: 24, maxCount: 1500)
        #expect(retained.count == 1500)
        #expect(!retained.contains { $0.id == snaps.last!.id })
        #expect(retained.contains { $0.id == snaps[0].id })
    }

    @Test func outputSortedByTimestamp() {
        let snaps = Array(makeSnaps([-3, -1, -2], now: now).shuffled())
        let retained = DataStore.retainedSnapshots(snaps, now: now)
        #expect(retained.map(\.timestamp) == retained.map(\.timestamp).sorted())
    }
}
