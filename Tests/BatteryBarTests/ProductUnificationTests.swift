import Foundation
import Testing
@testable import BatteryBar

@Suite struct ProductUnificationTests {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        return value
    }
    private func date(_ day: Int, month: Int = 10, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour))!
    }

    @Test func unknownStateDoesNotPretendToBeOnBattery() {
        let result = PowerStatePresentation.resolve(external: nil, charging: false, level: 0,
                                                    target: nil, behavior: nil)
        #expect(result.mode == .unknown)
        #expect(!result.title.contains("电池供电"))
    }

    @Test func allFiveLimitsShareTheSameStateAndNeverInferOptimization() {
        for limit in [80, 85, 90, 95, 100] {
            let result = PowerStatePresentation.resolve(external: true, charging: false,
                                                        level: Double(limit), target: limit, behavior: nil)
            #expect(result.title == "电源供电")
            #expect(result.mode == .external)
            #expect(!result.detail.contains("优化"))
            #expect(result.detail.contains(limit == 100 ? "充满" : "\(limit)%"))
        }
    }

    @Test func chargingTakesPrecedenceEvenWhenAboveConfiguredLimit() {
        let result = PowerStatePresentation.resolve(external: true, charging: true, level: 90,
                                                    target: 80, behavior: nil)
        #expect(result.mode == .charging)
        #expect(result.title.contains("正在充电"))
        #expect(!result.detail.contains("未充电"))
    }

    @Test func belowLimitIsNotClaimedAsCompletedOrOptimized() {
        let result = PowerStatePresentation.resolve(external: true, charging: false, level: 79,
                                                    target: 80, behavior: nil)
        #expect(result.detail == "电池当前未充电 · 充电上限 80%")
    }

    @Test func confirmedPauseIsPresentedWithoutConfusingPowerSource() {
        let behavior = ChargingBehaviorObservation(state: .otherConfirmedPause,
                                                   reason: .thermalProtection, source: "fixture", observedAt: date(26))
        let result = PowerStatePresentation.resolve(external: true, charging: false, level: 80,
                                                    target: 80, behavior: behavior)
        #expect(result.title == "电源供电" && result.detail.contains("温度保护"))
    }

    @Test func dayMonthAndLifetimeHaveExplicitBounds() {
        let first = date(25), now = date(26)
        let day = HistoryCalendar.bounds(period: .day, selection: first, first: first, now: now, calendar: calendar)
        #expect(day.start == calendar.startOfDay(for: first))
        #expect(day.duration == 86_400)
        let month = HistoryCalendar.bounds(period: .month, selection: first, first: first, now: now, calendar: calendar)
        #expect(calendar.component(.day, from: month.start) == 1)
        #expect(calendar.component(.month, from: month.end) == 11)
        let all = HistoryCalendar.bounds(period: .all, selection: now, first: first, now: now, calendar: calendar)
        #expect(all.start == calendar.startOfDay(for: first) && all.end == now)
    }

    @Test func dateNavigationStopsAtRecordingStartAndToday() {
        let first = date(25), now = date(26)
        #expect(HistoryCalendar.move(-1, period: .day, selection: first, first: first, now: now, calendar: calendar) == first)
        #expect(HistoryCalendar.move(1, period: .day, selection: now, first: first, now: now, calendar: calendar) == now)
        #expect(HistoryCalendar.move(-1, period: .month, selection: now, first: first, now: now, calendar: calendar) == first)
        #expect(HistoryCalendar.move(1, period: .month, selection: now, first: first, now: now, calendar: calendar) == now)
    }

    @Test func dateTitleUsesHumanDatesAndCorrectWeekday() {
        let now = date(26)
        let today = HistoryCalendar.title(period: .day, selection: now, first: date(25), now: now, calendar: calendar)
        #expect(today.contains("今天") && today.contains("10月26日") && today.contains("星期一"))
        #expect(HistoryCalendar.title(period: .month, selection: now, first: date(25), now: now, calendar: calendar) == "2026年10月")
        #expect(HistoryCalendar.title(period: .all, selection: now, first: date(25), now: now, calendar: calendar) == "开始记录至今")
    }

    @Test func navigationOpensTheRequestedSectionAndSubpage() {
        let navigation = ProductNavigation()
        navigation.go(.health)
        #expect(navigation.section == .battery && navigation.batteryHealth)
        navigation.go(.battery)
        #expect(navigation.section == .battery && !navigation.batteryHealth)
        navigation.go(.energy)
        #expect(navigation.section == .energy)
        navigation.go(.settings)
        #expect(navigation.section == .settings)
        navigation.go(.overview)
        #expect(navigation.section == .overview)
    }
}
