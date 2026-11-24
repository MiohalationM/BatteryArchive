import Testing
@testable import BatteryArchive

@Suite struct BatteryLevelTests {
    @Test(arguments: Array(0...100))
    func systemIntegerPercentStaysExact(_ percent: Int) throws {
        let level = try #require(BatteryReader.normalizedBatteryLevel(percent, maxCapacity: 100))
        #expect(level == Double(percent))
        #expect(BatteryLevelPresentation.percent(level) == percent)
    }

    @Test func legacyFloatingPointReadingsDoNotLoseOnePercent() {
        for percent in 0...100 {
            let level = Double(percent) / 100 * 100
            #expect(BatteryLevelPresentation.percent(level) == percent)
        }
    }

    @Test func fractionalCapacityIsPreservedAndOnlyDisplayIsRounded() throws {
        let level = try #require(BatteryReader.normalizedBatteryLevel(2303, maxCapacity: 4000))
        #expect(level == 57.575)
        #expect(BatteryLevelPresentation.percent(level) == 58)
        #expect(BatteryLevelPresentation.percent(57.49) == 57)
        #expect(BatteryLevelPresentation.percent(57.5) == 58)
    }

    @Test func invalidCapacityRemainsUnavailableAndOverfullIsClamped() {
        #expect(BatteryReader.normalizedBatteryLevel(-1, maxCapacity: 100) == nil)
        #expect(BatteryReader.normalizedBatteryLevel(58, maxCapacity: 0) == nil)
        #expect(BatteryReader.normalizedBatteryLevel(58, maxCapacity: -1) == nil)
        #expect(BatteryReader.normalizedBatteryLevel(101, maxCapacity: 100) == 100)
    }
}
