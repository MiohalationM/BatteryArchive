import Foundation
import Testing
@testable import BatteryArchive

@Suite @MainActor struct PowerSamplerPublicationTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(at date: Date, batteryPower: Double = 12,
                         inputPower: Double = 25, temperature: Double = 30) -> BatteryReader.BatteryReading {
        let info = BatteryInfo(
            designCapacity: 4000, maxCapacity: 3800, cycleCount: 10,
            voltage: 11500, instantAmperage: 1000, temperature: temperature,
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
        // Foreground surface enabled without start(): tests never launch timers or hardware services.
        sampler.setReadingSurface(.statusPopover, visible: true)
        sampler.publishBaseTelemetry(reading(at: t0))
        #expect(sampler.currentPowerAvailable)
        #expect(sampler.currentBatteryPowerAvailable)
        #expect(sampler.currentAdapterInputAvailable)
        #expect(sampler.currentTemperature == 30)
        #expect(sampler.temperatureMetric.value == 30)

        let failureAt = t0.addingTimeInterval(5)
        sampler.publishBaseTelemetry(nil, at: failureAt)
        #expect(!sampler.currentSourceKnown)
        #expect(!sampler.currentPowerAvailable)
        #expect(!sampler.currentBatteryPowerAvailable)
        #expect(!sampler.currentAdapterInputAvailable)
        #expect(sampler.currentTemperature == nil)
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
        #expect(sampler.currentTemperature == 30)
        #expect(sampler.temperatureMetric.value == 30)
        #expect(sampler.lastUpdateTime == recoveredAt)
    }

    @Test func currentTemperatureUsesThresholdGatingAndClearsOnUnavailableOrFailure() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SamplerTemperature-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = PowerSampler(dataStore: DataStore(directory: directory))

        sampler.publishBaseTelemetry(reading(at: t0, temperature: 30.10))
        #expect(sampler.currentTemperature == 30.10)

        // Sub-0.05°C jitter is gated out
        sampler.publishBaseTelemetry(reading(at: t0.addingTimeInterval(5), temperature: 30.14))
        #expect(sampler.currentTemperature == 30.10)

        // Exact 0.05°C delta publishes (including binary64 rounding pair 30.10 -> 30.15)
        sampler.publishBaseTelemetry(reading(at: t0.addingTimeInterval(10), temperature: 30.15))
        #expect(sampler.currentTemperature == 30.15)

        // Unreadable sentinel (<= 0.25°C around 0) clears to nil
        sampler.publishBaseTelemetry(reading(at: t0.addingTimeInterval(15), temperature: 0.1))
        #expect(sampler.currentTemperature == nil)

        // Negative winter temperature publishes cleanly
        sampler.publishBaseTelemetry(reading(at: t0.addingTimeInterval(20), temperature: -5.0))
        #expect(sampler.currentTemperature == -5.0)

        // Failed base reading clears temperature to nil
        sampler.publishBaseTelemetry(nil, at: t0.addingTimeInterval(25))
        #expect(sampler.currentTemperature == nil)
    }

    @Test func backgroundReadAtOnlyTicksSkipRedundantWritesAndFlushOnForeground() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SamplerBackgroundGate-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let sampler = PowerSampler(dataStore: DataStore(directory: directory))
        #expect(!sampler.isForegroundReadingActive)

        // Initial semantic publish in background updates metrics and lastUpdateTime
        sampler.publishBaseTelemetry(reading(at: t0))
        #expect(sampler.lastUpdateTime == t0)
        #expect(sampler.loadMetric.readAt == t0)
        #expect(sampler.batteryPowerMetric.readAt == t0)
        #expect(sampler.inputPowerMetric.readAt == t0)
        #expect(sampler.temperatureMetric.readAt == t0)

        // Identical reading in background (only readAt advances) skips redundant @Observable writes
        let t1 = t0.addingTimeInterval(15)
        sampler.publishBaseTelemetry(reading(at: t1))
        #expect(sampler.lastUpdateTime == t0)
        #expect(sampler.loadMetric.readAt == t0)
        #expect(sampler.batteryPowerMetric.readAt == t0)
        #expect(sampler.inputPowerMetric.readAt == t0)
        #expect(sampler.temperatureMetric.readAt == t0)

        // Semantic change in background publishes the changed metric immediately while leaving unchanged metrics untouched
        let t2 = t0.addingTimeInterval(30)
        sampler.publishBaseTelemetry(reading(at: t2, batteryPower: 18))
        #expect(sampler.batteryPowerMetric.value == 18)
        #expect(sampler.batteryPowerMetric.readAt == t2)
        #expect(sampler.lastUpdateTime == t2)
        #expect(sampler.loadMetric.readAt == t0)

        // Another readAt-only background tick defers timestamps until foreground opens
        let t3 = t0.addingTimeInterval(45)
        sampler.publishBaseTelemetry(reading(at: t3, batteryPower: 18))
        #expect(sampler.lastUpdateTime == t2)
        #expect(sampler.batteryPowerMetric.readAt == t2)

        // Entering foreground flushes deferred timestamps into lastUpdateTime and all 4 metrics
        sampler.setReadingSurface(.statusPopover, visible: true)
        #expect(sampler.isForegroundReadingActive)
        #expect(sampler.lastUpdateTime == t3)
        #expect(sampler.loadMetric.readAt == t3)
        #expect(sampler.batteryPowerMetric.readAt == t3)
        #expect(sampler.inputPowerMetric.readAt == t3)
        #expect(sampler.temperatureMetric.readAt == t3)

        // While foreground is active, readAt-only ticks update immediately
        let t4 = t0.addingTimeInterval(50)
        sampler.publishBaseTelemetry(reading(at: t4, batteryPower: 18))
        #expect(sampler.lastUpdateTime == t4)
        #expect(sampler.loadMetric.readAt == t4)
        #expect(sampler.batteryPowerMetric.readAt == t4)
    }
}
