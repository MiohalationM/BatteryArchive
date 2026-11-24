import SwiftUI
import Charts

/// 历史趋势曲线与实时指标隔离。父页面刷新数字时，只要输入点不变，
/// EquatableView 会跳过全部 Chart marks 的重新构造。
/// 曲线口径：v5 分钟聚合的 systemPowerAverage / temperatureAverage；
/// 覆盖率不足的分钟留缺口，不外推、不插值。
struct TrendChartPlot: View, @MainActor Equatable {
    let points: [TrendPoint]
    let timeRange: TimeRange
    let unit: String
    let tintColor: Color
    var isTemperature = false

    @State private var selectedTime: Date?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.points == rhs.points && lhs.timeRange == rhs.timeRange
            && lhs.unit == rhs.unit && lhs.tintColor == rhs.tintColor
            && lhs.isTemperature == rhs.isTemperature
    }

    /// 按 breakBefore 切分成连续段；每段独立绘制，段间自然留缺口。
    private func segments(in domain: ClosedRange<Date>) -> [[TrendPoint]] {
        var result: [[TrendPoint]] = []
        var current: [TrendPoint] = []
        for point in points where domain.contains(point.time) {
            if point.breakBefore, !current.isEmpty {
                result.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    var body: some View {
        let domain = xDomain
        let segments = segments(in: domain)
        let visibleValues = segments.flatMap { $0.map(\.value) }
        let yLower = isTemperature ? min(0, floor((visibleValues.min() ?? 0) / 5) * 5) : 0
        let yUpper = ceil(max(2, visibleValues.max() ?? 2) * 1.18 / 2) * 2

        return Chart {
            // 每个连续段一个独立 ForEach：Charts 会把同组 LineMark/AreaMark 连成一体，
            // 段与段之间自然留缺口，绝不跨缺口插值。
            ForEach(Array(segments.enumerated()), id: \.offset) { _, segment in
                if segment.count == 1, let only = segment.first {
                    // 孤立单点段无法形成 LineMark/AreaMark，显式绘制 PointMark 避免有效分钟点在图上“隐身”。
                    PointMark(
                        x: .value("时间", only.time),
                        y: .value("值", only.value)
                    )
                    .foregroundStyle(tintColor)
                    .symbolSize(32)
                } else {
                    ForEach(Array(segment.enumerated()), id: \.offset) { _, point in
                        AreaMark(
                            x: .value("时间", point.time),
                            yStart: .value("基线", yLower),
                            yEnd: .value("值", point.value),
                            series: .value("连续段", segment.first?.time ?? point.time)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [tintColor.opacity(0.22), tintColor.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("时间", point.time),
                            y: .value("值", point.value),
                            series: .value("连续段", segment.first?.time ?? point.time)
                        )
                        .foregroundStyle(tintColor)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    }
                }
            }

            if let selectedTime, let closest = closestPoint(to: selectedTime, in: domain) {
                RuleMark(x: .value("选中", closest.time))
                    .foregroundStyle(tintColor.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                PointMark(x: .value("时间", closest.time), y: .value("值", closest.value))
                    .foregroundStyle(tintColor.opacity(0.22))
                    .symbolSize(160)
                PointMark(x: .value("时间", closest.time), y: .value("值", closest.value))
                    .foregroundStyle(tintColor)
                    .symbolSize(52)
                    .annotation(
                        position: .top,
                        alignment: .center,
                        overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                    ) {
                        tooltip(closest)
                    }
            }
        }
        .chartXSelection(value: $selectedTime)
        .chartXScale(domain: domain, range: .plotDimension(padding: 6))
        .chartXAxis {
            AxisMarks(values: .stride(by: timeRange.axisStride.component, count: timeRange.axisStride.count)) { value in
                let isLast = value.as(Date.self).map {
                    $0.timeIntervalSince(domain.lowerBound) > domain.upperBound.timeIntervalSince(domain.lowerBound) * 0.9
                } ?? false
                AxisValueLabel(anchor: isLast ? .topTrailing : .top) {
                    if let date = value.as(Date.self) {
                        Text(date, format: .dateTime.hour().minute())
                            .font(BBType.micro.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .fixedSize()
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundStyle(.quaternary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 5)) { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(yLabel(number))
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundStyle(.quinary)
            }
        }
        .chartYScale(domain: yLower...max(yLower + 2, yUpper))
        .chartPlotStyle { $0.clipped() }
        .frame(height: 184)
        .chartSurface()
    }

    private func yLabel(_ number: Double) -> String {
        isTemperature ? String(format: "%.0f°", number) : String(format: "%.0f%@", number, unit)
    }

    private func closestPoint(to date: Date, in domain: ClosedRange<Date>) -> TrendPoint? {
        points.lazy.filter { domain.contains($0.time) }.min {
            abs($0.time.timeIntervalSince(date)) < abs($1.time.timeIntervalSince(date))
        }
    }

    private func tooltip(_ point: TrendPoint) -> some View {
        VStack(spacing: 2) {
            Text(point.time, format: .dateTime.hour().minute())
                .font(BBType.micro.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(
                isTemperature
                    ? String(format: "%.1f°C", point.value)
                    : String(format: "%.1f%@", point.value, unit)
            )
            .font(.system(size: 12, weight: .bold, design: .rounded).monospacedDigit())
            .foregroundStyle(Color.bbInk)
            if isTemperature, let maximum = point.maximum {
                Text(String(format: "峰值 %.1f°C", maximum))
                    .font(BBType.micro.monospacedDigit())
                    .foregroundStyle(Color.bbAmber)
            }
            if let coverage = point.coverage {
                Text(String(format: "覆盖 %.0f%%", coverage * 100))
                    .font(BBType.micro)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .productSurface(.card, tint: tintColor, cornerRadius: 10)
    }

    /// 选中的范围始终对应真实墙上时间，而不是被现有少量样本自动撑满。
    private var xDomain: ClosedRange<Date> {
        let now = Date()
        let end = max(now, points.last?.time ?? now)
        return timeRange.domain(endingAt: end)
    }
}
