import Foundation
import Testing
import SwiftUI
import AppKit
@testable import BatteryArchive

@Suite struct UsageVisualTests {
    /// Exercise the actual Swift Charts view with edge SOC values, a long gap,
    /// a 2-minute excursion and endpoint annotations. No production data/UI.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BA_RENDER_USAGE_QA"] == "1"))
    @MainActor func timelineRendersEndpointsAndGaps() throws {
        let output = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(".build/qa-20261025-usage")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let start = calendar.startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let continuity = UUID(), session = UUID()
        var day = UsageDayReview(date: start, end: end, elapsedSeconds: 86_400)
        day.levels = [
            .init(date: start, level: 100, segment: 0),
            .init(date: start.addingTimeInterval(120), level: 98, segment: 0),
            .init(date: start.addingTimeInterval(80_000), level: 8, segment: 1),
            .init(date: end.addingTimeInterval(-1), level: 0, segment: 1)
        ]
        day.spans = [
            UsageSpan(start: start, end: start.addingTimeInterval(120), activity: .batteryScreenOn,
                      sessionID: session, continuityID: continuity),
            UsageSpan(start: start.addingTimeInterval(120), end: start.addingTimeInterval(300),
                      activity: .onPower, continuityID: continuity),
            UsageSpan(start: start.addingTimeInterval(80_000), end: end,
                      activity: .batteryScreenOff, sessionID: UUID(), continuityID: UUID())
        ]
        for (name, width, selected) in [
            ("first-point", 650.0, start),
            ("last-point", 650.0, end.addingTimeInterval(-1)),
            ("narrow", 560.0, start)
        ] {
            let view = UsageDayTimeline(day: day, selectedTime: selected)
                .padding(18).frame(width: width)
                .background(Color(nsColor: .windowBackgroundColor))
                .environment(\.calendar, calendar).environment(\.timeZone, calendar.timeZone)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let image = try #require(renderer.cgImage)
            let representation = NSBitmapImageRep(cgImage: image)
            let data = try #require(representation.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent("usage-timeline-\(name).png"))
            #expect(image.width == Int(width * 2))
        }
    }
}
