import Foundation
import Observation

enum ProductSection: Int, CaseIterable, Identifiable {
    case overview, energy, battery, settings
    var id: Int { rawValue }
}

enum ProductDestination { case overview, energy, battery, health, settings }

@Observable final class ProductNavigation {
    var section: ProductSection = .overview
    var batteryHealth = false

    func go(_ destination: ProductDestination) {
        switch destination {
        case .overview: section = .overview
        case .energy: section = .energy
        case .battery: batteryHealth = false; section = .battery
        case .health: batteryHealth = true; section = .battery
        case .settings: section = .settings
        }
    }
}

enum BatteryLevelPresentation {
    /// Round normalized SOC for display; keep fractional readings in telemetry/history.
    static func percent(_ level: Double) -> Int {
        guard level.isFinite else { return 0 }
        return min(100, max(0, Int(level.rounded())))
    }
}

struct PowerStatePresentation: Equatable {
    enum Mode { case unknown, battery, charging, external }
    var mode: Mode
    var title: String
    var detail: String
    var symbol: String

    static func resolve(external: Bool?, charging: Bool, level: Double,
                        target: Int?, behavior: ChargingBehaviorObservation?) -> Self {
        guard let external else {
            return .init(mode: .unknown, title: "正在读取供电状态", detail: "有效读数就绪后自动更新", symbol: "battery.0percent")
        }
        if !external {
            return .init(mode: .battery, title: "电池供电", detail: "正在使用电池", symbol: "battery.75percent")
        }
        let validTarget = target.flatMap { (80...100).contains($0) ? $0 : nil }
        if charging {
            return .init(mode: .charging, title: "电源供电 · 正在充电",
                         detail: validTarget.map { "充电目标 \($0)%" } ?? "正在向电池充电",
                         symbol: "battery.100percent.bolt")
        }
        if behavior?.reason == .thermalProtection {
            return .init(mode: .external, title: "电源供电", detail: "系统因温度保护暂停充电", symbol: "powerplug.fill")
        }
        if let behavior, behavior.state == .otherConfirmedPause {
            return .init(mode: .external, title: "电源供电", detail: behavior.displayLabel, symbol: "powerplug.fill")
        }
        let detail: String
        if let validTarget, level.isFinite, level >= Double(validTarget) {
            detail = validTarget == 100 ? "电池已充满" : "已达充电上限 \(validTarget)% · 电池未充电"
        } else if let validTarget {
            detail = "电池当前未充电 · 充电上限 \(validTarget)%"
        } else {
            detail = "电池当前未充电"
        }
        return .init(mode: .external, title: "电源供电", detail: detail, symbol: "powerplug.fill")
    }
}

enum HistoryPeriod: String, CaseIterable, Identifiable {
    case day = "日", month = "月", all = "累计"
    var id: Self { self }
}

enum HistoryCalendar {
    static func bounds(period: HistoryPeriod, selection: Date, first: Date, now: Date,
                       calendar: Calendar) -> DateInterval {
        let earliest = min(first, now)
        let day = calendar.startOfDay(for: min(now, max(earliest, selection)))
        switch period {
        case .day:
            if let interval = calendar.dateInterval(of: .day, for: day) {
                return interval
            }
            return DateInterval(start: day, end: calendar.date(byAdding: .day, value: 1, to: day)!)
        case .month:
            return calendar.dateInterval(of: .month, for: day)!
        case .all:
            let start = calendar.startOfDay(for: earliest)
            return DateInterval(start: start, end: max(start, now))
        }
    }

    static func move(_ offset: Int, period: HistoryPeriod, selection: Date, first: Date,
                     now: Date, calendar: Calendar) -> Date {
        guard period != .all else { return selection }
        let component: Calendar.Component = period == .day ? .day : .month
        let anchor = period == .month ? calendar.dateInterval(of: .month, for: selection)!.start
            : calendar.startOfDay(for: selection)
        let next = calendar.date(byAdding: component, value: offset, to: anchor)!
        return min(now, max(first, next))
    }

    static func title(period: HistoryPeriod, selection: Date, first: Date, now: Date,
                      calendar: Calendar) -> String {
        if period == .all { return "开始记录至今" }
        let format = period == .month ? "yyyy年M月" : "M月d日 EEEE"
        let label = ProductDateFormatting.string(
            from: selection,
            format: format,
            timeZone: calendar.timeZone,
            localeIdentifier: "zh_CN"
        )
        return period == .day && calendar.isDate(selection, inSameDayAs: now) ? "今天 · \(label)" : label
    }
}

/// 线程安全的 DateFormatter 缓存，避免 SwiftUI View.body 与高频列表渲染反复构造 ICU 格式化器。
enum ProductDateFormatting {
    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var formatters: [String: DateFormatter] = [:]

        func format(
            _ date: Date,
            format: String,
            timeZone: TimeZone,
            localeIdentifier: String?
        ) -> String {
            let key = "\(timeZone.identifier)|\(localeIdentifier ?? "")|\(format)"
            lock.lock()
            defer { lock.unlock() }
            let formatter: DateFormatter
            if let existing = formatters[key] {
                formatter = existing
            } else {
                let created = DateFormatter()
                var calendar = Calendar(identifier: .gregorian)
                calendar.timeZone = timeZone
                created.calendar = calendar
                created.timeZone = timeZone
                if let localeIdentifier {
                    created.locale = Locale(identifier: localeIdentifier)
                }
                created.dateFormat = format
                formatters[key] = created
                formatter = created
            }
            return formatter.string(from: date)
        }
    }

    private static let cache = Cache()

    static func string(
        from date: Date,
        format: String,
        timeZone: TimeZone,
        localeIdentifier: String? = nil
    ) -> String {
        cache.format(date, format: format, timeZone: timeZone, localeIdentifier: localeIdentifier)
    }
}
