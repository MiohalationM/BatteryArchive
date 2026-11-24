import Testing
import Foundation
@testable import BatteryArchive

/// BatterySnapshot 编解码与历史兼容测试（纯本地存储）。
@Suite struct BatterySnapshotTests {

    @Test func codableRoundTrip() throws {
        var snap = BatterySnapshot(
            timestamp: Date(timeIntervalSince1970: 1_720_780_800),
            level: 42.0,
            isCharging: false,
            wattage: 8.5,
            systemPowerAvailable: true,
            systemPowerIsEstimated: false,
            externalConnected: false
        )
        snap.aggregateWindowStart = Date(timeIntervalSince1970: 1_720_780_740)
        snap.systemEnergyWh = 0.14
        snap.systemPowerAverage = 8.4
        snap.systemPowerPeak = 11.2
        snap.systemCoverage = 1.0
        snap.temperatureAverage = 29.3
        snap.temperatureMaximum = 30.1
        snap.temperatureCoverage = 1.0

        let data = try JSONEncoder().encode(snap)
        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: data)

        #expect(decoded == snap)
    }

    @Test func decodesLegacyFullFieldJSONWithoutDataLoss() throws {
        let id = UUID()
        let json = """
        {
          "id": "\(id.uuidString)",
          "timestamp": 1720780800.0,
          "level": 78.5,
          "isCharging": true,
          "wattage": 14.2,
          "batteryPower": 22.0,
          "systemPowerAvailable": true,
          "systemPowerIsEstimated": false,
          "externalConnected": true,
          "temperature": 32.4,
          "screenOn": true,
          "cpuPower": 4.1,
          "gpuPower": 1.2,
          "displayPower": 0.0,
          "dramPower": 0.8,
          "dirty": true,
          "recordedLocally": true,
          "sourceDeviceID": "legacy-device",
          "lowPowerModeEnabled": false,
          "thermalState": "正常",
          "aggregateWindowStart": 1720780740.0,
          "systemEnergyWh": 0.23,
          "systemPowerAverage": 13.8,
          "systemPowerPeak": 16.5,
          "systemCoverage": 1.0,
          "batteryChargeWh": 0.35,
          "batteryDischargeWh": 0.0,
          "temperatureAverage": 32.1,
          "temperatureMaximum": 32.8,
          "temperatureCoverage": 1.0,
          "screenOnFraction": 1.0,
          "lowPowerModeFraction": 0.0,
          "maximumThermalState": "正常",
          "displayBrightness": 0.55,
          "brightnessAvailable": true
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(BatterySnapshot.self, from: json)
        #expect(decoded.id == id)
        #expect(abs(decoded.level - 78.5) < 0.0001)
        #expect(decoded.isCharging == true)
        #expect(abs(decoded.wattage - 14.2) < 0.0001)
        #expect(decoded.systemPowerAvailable == true)
        #expect(decoded.systemPowerIsEstimated == false)
        #expect(decoded.externalConnected == true)
        #expect(decoded.systemEnergyWh == 0.23)
        #expect(decoded.systemPowerAverage == 13.8)
        #expect(decoded.systemPowerPeak == 16.5)
        #expect(decoded.systemCoverage == 1.0)
        #expect(decoded.temperatureAverage == 32.1)
        #expect(decoded.temperatureMaximum == 32.8)
        #expect(decoded.temperatureCoverage == 1.0)
    }

    @Test func identifiableUsesStableID() {
        let snap = BatterySnapshot(
            timestamp: Date(),
            level: 0,
            isCharging: false,
            wattage: 0
        )
        #expect(snap.id == snap.id)
    }
}
