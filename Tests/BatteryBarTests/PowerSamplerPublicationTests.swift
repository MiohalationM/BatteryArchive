import Foundation
import Testing
@testable import BatteryBar

@Suite @MainActor struct PowerSamplerPublicationTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(at date: Date, batteryPower: Double = 12,
                         inputPower: Double = 25) -> BatteryReader.BatteryReading {
        let info = BatteryInfo(
            designCapacity: 4000, maxCapacity: 3800, cycleCount: 10,
            voltage: 11500, instantAmperage: 1000, temperature: 30,
            isCharging: true, externalConnected: true, chargeStatus: nil,
            systemPower: 13, batteryPower: batteryPower, batteryPowerAvailable: true,
            adapterInputPower: inputPower, adapterInputPowerAvailable: true,
            systemPowerAvailable: true, systemPowerIsEstimated: false,
            adapterWatts: 65, adapterProtocol: "USB-PD"
        )
        return .init(
            powerSource: .init(level: 72, isCharging: true, isPluggedIn: true,
                               chargeStatus: nil, timeRemaining: 90),
            batteryInfo: info,
            provenance: .init(systemLoadSource: .telemetrySystemLoad,
                              systemLoadIsEstimated: false,
                              batteryPowerSource: .batteryPowerTelemetry,
                              temperatureSource: .smartBatteryTemperature),
            readAt: date
        )
    }

    @Test func failureInvalidatesPublishedReadingsWithoutInventingBatteryState() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SamplerPublication-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = DataStore(directory: directory)
        let sampler = PowerSampler(dataStore: store)
        // No start(): publication tests must never launch sampling or system services.
        sampler.publishBaseTelemetry(reading(at: t0))
        #expect(sampler.currentPowerAvailable)
        #expect(sampler.currentBatteryPowerAvailable)
        #expect(sampler.currentAdapterInputAvailable)
        #expect(sampler.temperatureMetric.value == 30)

        let failureAt = t0.addingTimeInterval(5)
        sampler.publishBaseTelemetry(nil, at: failureAt)
        #expect(!sampler.currentSourceKnown)
        #expect(!sampler.currentPowerAvailable)
        #expect(!sampler.currentBatteryPowerAvailable)
        #expect(!sampler.currentAdapterInputAvailable)
        #expect(sampler.currentLevel == 72)
        #expect(sampler.currentIsCharging)
        #expect(sampler.currentExternalConnected)
        #expect(sampler.lastUpdateTime == t0)
        #expect(sampler.currentVoltage == 0)
        #expect(sampler.currentAmperage == 0)
        for metric in [sampler.loadMetric, sampler.batteryPowerMetric,
                       sampler.inputPowerMetric, sampler.temperatureMetric] {
            #expect(metric.value == nil)
            #expect(metric.availability == .unavailable)
            #expect(metric.source == .unavailable)
            #expect(metric.readAt == failureAt)
            #expect(metric.changedAt == failureAt)
            #expect(metric.sourceSampleAt == nil)
        }
        sampler.publishBaseTelemetry(nil, at: failureAt.addingTimeInterval(5))
        #expect(sampler.loadMetric.changedAt == failureAt)
        #expect(sampler.loadMetric.readAt == failureAt.addingTimeInterval(5))
        #expect(store.allSnapshots().isEmpty)
    }

    @Test func successfulReadAfterFailureRestoresAvailabilityIncludingTrueZero() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SamplerRecovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = PowerSampler(dataStore: DataStore(directory: directory))
        sampler.publishBaseTelemetry(reading(at: t0))
        sampler.publishBaseTelemetry(nil, at: t0.addingTimeInterval(5))
        let recoveredAt = t0.addingTimeInterval(10)
        sampler.publishBaseTelemetry(reading(at: recoveredAt, batteryPower: 0, inputPower: 0))
        #expect(sampler.currentSourceKnown)
        #expect(sampler.currentPowerAvailable)
        #expect(sampler.loadMetric.value == 13)
        #expect(sampler.currentBatteryPowerAvailable)
        #expect(sampler.currentBatteryPower == 0)
        #expect(sampler.batteryPowerMetric.value == 0)
        #expect(sampler.currentAdapterInputAvailable)
        #expect(sampler.currentAdapterInputPower == 0)
        #expect(sampler.inputPowerMetric.value == 0)
        #expect(sampler.inputPowerMetric.changedAt == recoveredAt)
        #expect(sampler.temperatureMetric.value == 30)
        #expect(sampler.lastUpdateTime == recoveredAt)
    }
}
