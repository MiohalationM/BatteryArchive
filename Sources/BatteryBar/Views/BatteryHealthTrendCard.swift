import SwiftUI
import Charts

/// 电池健康度长期趋势卡：展示官方系统健康度（阶梯折线）、满充容量比参考线、
/// 满充容量（mAh，含出厂设计容量基准线）与循环次数趋势。
/// 直接消费 `[BatteryHealthRecord]`，供实时健康页与视觉 QA 测试共用。
struct BatteryHealthTrendCard: View {
    let records: [BatteryHealthRecord]
    var calendar: Calendar = .current

    @State private var metric: HealthTrendMetric = .healthPercent
    @State private var range: HealthTrendRange
    @State private var userSelectedRange = false
    @State private var selectedDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    init(records: [BatteryHealthRecord], calendar: Calendar = .current) {
        self.records = records
        self.calendar = calendar
        _range = State(initialValue: BatteryHealthTrendAnalysis.defaultRange(for: records, calendar: calendar))
    }

    private struct PlotEntry: Identifiable, Equatable {
        let date: Date
        let record: BatteryHealthRecord
        var id: String { record.id }
    }

    private struct MetricPoint: Identifiable {
        let id: String
        let date: Date
        let value: Double
    }

    private var rangeBinding: Binding<HealthTrendRange> {
        Binding(
            get: { range },
            set: { newValue in
                userSelectedRange = true
                range = newValue
                selectedDate = nil
            }
        )
    }

    private var metricBinding: Binding<HealthTrendMetric> {
        Binding(
            get: { metric },
            set: { newValue in
                metric = newValue
                selectedDate = nil
            }
        )
    }

    var body: some View {
        let filtered = BatteryHealthTrendAnalysis.filtered(records, range: range, calendar: calendar)
        let summary = BatteryHealthTrendAnalysis.summarize(filtered, calendar: calendar)
        let entries = plotEntries(from: filtered)

        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "健康度趋势", systemImage: "chart.xyaxis.line", tint: .bbMint) {
                ProductSegmentedControl(
                    title: "趋势指标",
                    selection: metricBinding,
                    options: HealthTrendMetric.allCases.map { .init($0, $0.rawValue) },
                    tint: .bbMint
                )
                .frame(width: 244)
            }

            HStack(spacing: 10) {
                ProductSegmentedControl(
                    title: "时间范围",
                    selection: rangeBinding,
                    options: HealthTrendRange.allCases.map { .init($0, $0.rawValue) },
                    tint: .bbBlue
                )
                .frame(width: 236)

                Spacer(minLength: 8)

                if let endCycles = summary.endCycleCount,
                   let designCycles = summary.designCycleCount,
                   designCycles > 0
                {
                    StatusPillBadge(
                        text: "循环进度 \(endCycles) / \(designCycles)",
                        systemImage: "arrow.2.circlepath",
                        tint: .bbBlue
                    )
                } else if summary.recordCount > 0 {
                    StatusPillBadge(
                        text: "已记录 \(summary.recordCount) 天",
                        systemImage: "calendar",
                        tint: .bbMint
                    )
                }
            }

            summaryTiles(summary: summary, filteredCount: filtered.count)

            legendRow(summary: summary, entries: entries)

            if records.isEmpty {
                EmptyChartState(
                    title: "正在建立健康度基线",
                    detail: "获取有效电池健康读数后将按天永久保存在本机，并自动绘制长期变化曲线",
                    systemImage: "chart.xyaxis.line"
                )
            } else if entries.isEmpty {
                EmptyChartState(
                    title: "所选范围内暂无记录",
                    detail: "切换到更长时间范围或「全部」以查看历史健康度记录",
                    systemImage: "calendar.badge.clock"
                )
            } else if !hasPlottableData(in: entries) {
                EmptyChartState(
                    title: "当前范围暂无该项读数",
                    detail: "已保存基础记录，系统提供有效读数后会自动显示趋势",
                    systemImage: "chart.xyaxis.line"
                )
            } else {
                trendChart(entries: entries, filtered: filtered, summary: summary)
            }

            if filtered.count == 1 {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Color.bbMint)
                    Text("已记录今日健康基线，持续使用后会自动绘制变化曲线；电池健康永久保存在本机。")
                        .font(BBType.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .productWell(tint: .bbMint, padding: 10)
            }

            Text("最大容量来自 macOS 系统报告，满充容量比为当前满充容量与设计容量之比，两者口径略有差异；记录按天永久保存在本机。")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .productCard(accent: .bbMint)
        .onAppear {
            syncDefaultRangeIfNeeded()
        }
        .onChange(of: records.count) { _, _ in
            syncDefaultRangeIfNeeded()
        }
    }

    private func syncDefaultRangeIfNeeded() {
        guard !userSelectedRange else { return }
        let recommended = BatteryHealthTrendAnalysis.defaultRange(for: records, calendar: calendar)
        if recommended != range {
            range = recommended
        }
    }

    // MARK: - 摘要指标（三等宽）

    private func summaryTiles(summary: BatteryHealthTrendSummary, filteredCount: Int) -> some View {
        let healthTile = healthSummaryTileValues(summary: summary, filteredCount: filteredCount)
        let cycleTile = cycleSummaryTileValues(summary: summary, filteredCount: filteredCount)
        let capacityTile = capacitySummaryTileValues(summary: summary, filteredCount: filteredCount)

        return LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
            spacing: 10
        ) {
            StatTile(
                icon: "heart.fill",
                tint: .bbMint,
                value: healthTile.value,
                unit: healthTile.unit,
                label: healthTile.label
            )
            StatTile(
                icon: "arrow.2.circlepath",
                tint: .bbBlue,
                value: cycleTile.value,
                unit: cycleTile.unit,
                label: cycleTile.label
            )
            StatTile(
                icon: "battery.100percent",
                tint: .bbTeal,
                value: capacityTile.value,
                unit: capacityTile.unit,
                label: capacityTile.label
            )
        }
    }

    private func healthSummaryTileValues(
        summary: BatteryHealthTrendSummary,
        filteredCount: Int
    ) -> (label: String, value: String, unit: String) {
        if filteredCount >= 2 {
            if let delta = summary.healthDeltaPercent, delta.isFinite {
                if abs(delta) < 0.05 {
                    return ("健康度变化", "稳定", "")
                }
                let formatted = abs(delta - delta.rounded()) < 0.05
                    ? String(format: "%+.0f", delta)
                    : String(format: "%+.1f", delta)
                return ("健康度变化", formatted, "%")
            }
            if let end = summary.endHealthPercent, end.isFinite {
                return ("最大容量", String(format: "%.0f", end), "%")
            }
            return ("健康度变化", "—", "")
        }
        if let end = summary.endHealthPercent, end.isFinite {
            return ("最大容量", String(format: "%.0f", end), "%")
        }
        return ("最大容量", "—", "")
    }

    private func cycleSummaryTileValues(
        summary: BatteryHealthTrendSummary,
        filteredCount: Int
    ) -> (label: String, value: String, unit: String) {
        if filteredCount >= 2, let delta = summary.cycleDelta {
            let value = delta > 0 ? "+\(delta)" : "\(delta)"
            return ("循环增量", value, "次")
        }
        if let end = summary.endCycleCount {
            return ("循环次数", "\(end)", "次")
        }
        return ("循环次数", "—", "")
    }

    private func capacitySummaryTileValues(
        summary: BatteryHealthTrendSummary,
        filteredCount: Int
    ) -> (label: String, value: String, unit: String) {
        if filteredCount >= 2, let delta = summary.capacityDeltaMah {
            let value = delta > 0 ? "+\(delta)" : "\(delta)"
            return ("容量变化", value, "mAh")
        }
        if let end = summary.endCapacityMah {
            return ("当前满充容量", "\(end)", "mAh")
        }
        return ("当前满充容量", "—", "")
    }

    // MARK: - 图例与当前选中摘要

    private func legendRow(summary: BatteryHealthTrendSummary, entries: [PlotEntry]) -> some View {
        let latestRatio = entries.last?.record.capacityRatioPercent
        return HStack(spacing: 12) {
            switch metric {
            case .healthPercent:
                ChartLegendItem(
                    label: "最大容量",
                    color: .bbMint,
                    value: summary.endHealthPercent.map { String(format: "%.0f%%", $0) }
                )
                dashedLegendItem(
                    label: "满充容量比",
                    color: .bbSlateBlue.opacity(0.72),
                    value: latestRatio.map { String(format: "%.1f%%", $0) }
                )
            case .capacityMah:
                ChartLegendItem(
                    label: "满充容量",
                    color: .bbMint,
                    value: summary.endCapacityMah.map { "\($0) mAh" }
                )
                if let design = summary.designCapacityMah, design > 0 {
                    dashedLegendItem(
                        label: "设计容量",
                        color: .bbBlue.opacity(0.75),
                        value: "\(design) mAh"
                    )
                }
            case .cycleCount:
                ChartLegendItem(
                    label: "累计循环",
                    color: .bbBlue,
                    value: summary.endCycleCount.map { "\($0) 次" }
                )
            }

            Spacer(minLength: 8)

            if summary.recordCount >= 2 {
                Text("已记录 \(summary.recordCount) 天")
                    .font(BBType.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            } else if summary.recordCount == 1 {
                Text("已建基线 · 永久本机保存")
                    .font(BBType.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func dashedLegendItem(label: String, color: Color, value: String? = nil) -> some View {
        HStack(spacing: 5) {
            HStack(spacing: 2.5) {
                Capsule().fill(color).frame(width: 5.5, height: 2.5)
                Capsule().fill(color).frame(width: 5.5, height: 2.5)
            }
            Text(label)
                .font(BBType.captionMedium)
                .foregroundStyle(.secondary)
            if let value {
                Text(value)
                    .font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.bbInk)
            }
        }
    }

    // MARK: - Swift Charts 渲染

    private func trendChart(
        entries: [PlotEntry],
        filtered: [BatteryHealthRecord],
        summary: BatteryHealthTrendSummary
    ) -> some View {
        let xDomain = chartXDomain(for: entries)
        let yDomain = chartYDomain(for: filtered)
        let accent: Color = metric == .cycleCount ? .bbBlue : .bbMint
        let selectedEntry = selectedDate.flatMap { closestEntry(to: $0, in: entries) }

        return Chart {
            switch metric {
            case .healthPercent:
                healthPercentMarks(entries: entries)
            case .capacityMah:
                capacityMarks(entries: entries, yDomain: yDomain, designCapacity: summary.designCapacityMah)
            case .cycleCount:
                cycleMarks(entries: entries)
            }

            if let selectedEntry {
                if let yVal = primaryYValue(for: selectedEntry.record) {
                    RuleMark(x: .value("选中", selectedEntry.date))
                        .foregroundStyle(accent.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    PointMark(x: .value("日期", selectedEntry.date), y: .value("值", yVal))
                        .foregroundStyle(accent.opacity(0.22))
                        .symbolSize(160)
                    PointMark(x: .value("日期", selectedEntry.date), y: .value("值", yVal))
                        .foregroundStyle(accent)
                        .symbolSize(54)
                        .annotation(
                            position: .top,
                            alignment: .center,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                        ) {
                            selectionTooltip(selectedEntry, accent: accent)
                        }
                } else {
                    RuleMark(x: .value("选中", selectedEntry.date))
                        .foregroundStyle(accent.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                        .annotation(
                            position: .top,
                            alignment: .center,
                            overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))
                        ) {
                            selectionTooltip(selectedEntry, accent: accent)
                        }
                }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartXScale(domain: xDomain, range: .plotDimension(padding: 10))
        .chartYScale(domain: yDomain)
        .chartXAxis {
            if entries.count == 1, let only = entries.first {
                AxisMarks(values: [only.date]) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(xAxisLabel(for: date, spanDays: summary.spanDays))
                                .font(BBType.micro.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(.quaternary)
                }
            } else {
                AxisMarks(values: .automatic(desiredCount: 5)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(xAxisLabel(for: date, spanDays: summary.spanDays))
                                .font(BBType.micro.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .fixedSize()
                        }
                    }
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(.quaternary)
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { value in
                AxisValueLabel {
                    if let number = value.as(Double.self) {
                        Text(yAxisLabel(for: number))
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                    .foregroundStyle(.quinary)
            }
        }
        .chartPlotStyle { $0.clipped() }
        .frame(height: 188)
        .chartSurface()
        .animation(reduceMotion ? nil : ProductMotion.reading, value: metric)
        .animation(reduceMotion ? nil : ProductMotion.reading, value: range)
    }

    @ChartContentBuilder
    private func healthPercentMarks(entries: [PlotEntry]) -> some ChartContent {
        let ratioPoints: [MetricPoint] = entries.compactMap { entry in
            guard let ratio = entry.record.capacityRatioPercent, ratio.isFinite else { return nil }
            return MetricPoint(id: entry.id, date: entry.date, value: ratio)
        }
        let systemPoints: [MetricPoint] = entries.compactMap { entry in
            guard let pct = entry.record.systemHealthPercent, pct.isFinite else { return nil }
            return MetricPoint(id: entry.id, date: entry.date, value: pct)
        }
        let systemNodes = stepNodePoints(from: systemPoints)
        let nodeSize: CGFloat = systemPoints.count == 1 ? 46 : (systemPoints.count <= 20 ? 28 : 18)

        // 次级参考线：满充容量比 %（轻虚线）
        if ratioPoints.count == 1, let only = ratioPoints.first {
            PointMark(
                x: .value("日期", only.date),
                y: .value("满充容量比", only.value)
            )
            .foregroundStyle(Color.bbSlateBlue.opacity(0.60))
            .symbolSize(28)
        } else {
            ForEach(ratioPoints) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("满充容量比", point.value),
                    series: .value("系列", "满充容量比")
                )
                .foregroundStyle(Color.bbSlateBlue.opacity(0.55))
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round, dash: [4, 3]))
            }
        }

        // 主系列：官方最大容量 %（阶梯线忠实呈现整数档位变化，不伪造插值）
        if systemPoints.count >= 2 {
            ForEach(systemPoints) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("最大容量", point.value),
                    series: .value("系列", "最大容量")
                )
                .foregroundStyle(Color.bbMint)
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
        }

        ForEach(systemNodes) { point in
            PointMark(
                x: .value("日期", point.date),
                y: .value("最大容量", point.value)
            )
            .foregroundStyle(Color.bbMint)
            .symbolSize(nodeSize)
        }
    }

    @ChartContentBuilder
    private func capacityMarks(
        entries: [PlotEntry],
        yDomain: ClosedRange<Double>,
        designCapacity: Int?
    ) -> some ChartContent {
        let capacityPoints: [MetricPoint] = entries.compactMap { entry in
            guard let fcc = entry.record.fullChargeCapacityMah, fcc > 0 else { return nil }
            return MetricPoint(id: entry.id, date: entry.date, value: Double(fcc))
        }

        if let design = designCapacity, design > 0 {
            RuleMark(y: .value("设计容量", Double(design)))
                .foregroundStyle(Color.bbBlue.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                .annotation(position: .top, alignment: .trailing, spacing: 3) {
                    Text("设计 \(design) mAh")
                        .font(BBType.micro.monospacedDigit())
                        .foregroundStyle(Color.bbBlue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(
                            Color.bbBlue.opacity(scheme == .dark ? 0.16 : 0.10),
                            in: Capsule()
                        )
                }
        }

        if capacityPoints.count == 1, let only = capacityPoints.first {
            PointMark(
                x: .value("日期", only.date),
                y: .value("满充容量", only.value)
            )
            .foregroundStyle(Color.bbMint)
            .symbolSize(46)
        } else {
            ForEach(capacityPoints) { point in
                AreaMark(
                    x: .value("日期", point.date),
                    yStart: .value("基线", yDomain.lowerBound),
                    yEnd: .value("满充容量", point.value),
                    series: .value("系列", "满充容量")
                )
                .foregroundStyle(
                    LinearGradient(
                        colors: [Color.bbMint.opacity(0.20), Color.bbMint.opacity(0.01)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .interpolationMethod(.linear)

                LineMark(
                    x: .value("日期", point.date),
                    y: .value("满充容量", point.value),
                    series: .value("系列", "满充容量")
                )
                .foregroundStyle(Color.bbMint)
                .interpolationMethod(.linear)
                .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }

            if capacityPoints.count <= 35 {
                ForEach(capacityPoints) { point in
                    PointMark(
                        x: .value("日期", point.date),
                        y: .value("满充容量", point.value)
                    )
                    .foregroundStyle(Color.bbMint)
                    .symbolSize(18)
                }
            }
        }
    }

    @ChartContentBuilder
    private func cycleMarks(entries: [PlotEntry]) -> some ChartContent {
        let cyclePoints = entries.map { entry in
            MetricPoint(id: entry.id, date: entry.date, value: Double(entry.record.cycleCount))
        }
        let cycleNodes = stepNodePoints(from: cyclePoints)
        let nodeSize: CGFloat = cyclePoints.count == 1 ? 46 : (cyclePoints.count <= 20 ? 28 : 18)

        if cyclePoints.count >= 2 {
            ForEach(cyclePoints) { point in
                LineMark(
                    x: .value("日期", point.date),
                    y: .value("循环次数", point.value),
                    series: .value("系列", "循环次数")
                )
                .foregroundStyle(Color.bbBlue)
                .interpolationMethod(.stepEnd)
                .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round, lineJoin: .round))
            }
        }

        ForEach(cycleNodes) { point in
            PointMark(
                x: .value("日期", point.date),
                y: .value("循环次数", point.value)
            )
            .foregroundStyle(Color.bbBlue)
            .symbolSize(nodeSize)
        }
    }

    private func stepNodePoints(from points: [MetricPoint]) -> [MetricPoint] {
        guard points.count > 45 else { return points }
        var result: [MetricPoint] = []
        for index in points.indices {
            let point = points[index]
            let isEndpoint = index == points.startIndex || index == points.index(before: points.endIndex)
            let isTransition = index > points.startIndex && abs(point.value - points[index - 1].value) > 0.001
            if isEndpoint || isTransition {
                result.append(point)
            }
        }
        return result
    }

    private func selectionTooltip(_ entry: PlotEntry, accent: Color) -> some View {
        let record = entry.record
        let dateText = ProductDateFormatting.string(
            from: entry.date,
            format: "yyyy年M月d日",
            timeZone: calendar.timeZone,
            localeIdentifier: "zh_CN"
        )
        return VStack(alignment: .leading, spacing: 3) {
            Text(dateText)
                .font(BBType.micro.monospacedDigit())
                .foregroundStyle(.secondary)
            if let pct = record.systemHealthPercent {
                Text(String(format: "最大容量 %.0f%%", pct))
                    .font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.bbInk)
            }
            if let fcc = record.fullChargeCapacityMah {
                Text("满充 \(fcc) mAh")
                    .font(BBType.micro.monospacedDigit())
                    .foregroundStyle(Color.bbMint)
            }
            Text("循环 \(record.cycleCount) 次")
                .font(BBType.micro.monospacedDigit())
                .foregroundStyle(Color.bbBlue)
            if let peakTemp = record.peakTemperatureC {
                Text(String(format: "峰值温度 %.1f°C", peakTemp))
                    .font(BBType.micro.monospacedDigit())
                    .foregroundStyle(Color.bbAmber)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .productSurface(.card, tint: accent, cornerRadius: 10)
    }

    // MARK: - 坐标轴与辅助计算

    private func plotEntries(from records: [BatteryHealthRecord]) -> [PlotEntry] {
        records.compactMap { record in
            let date = record.parsedDate(calendar: calendar) ?? record.recordedAt
            return PlotEntry(date: date, record: record)
        }
        .sorted { $0.date < $1.date }
    }

    private func hasPlottableData(in entries: [PlotEntry]) -> Bool {
        switch metric {
        case .healthPercent:
            entries.contains { $0.record.systemHealthPercent != nil || $0.record.capacityRatioPercent != nil }
        case .capacityMah:
            entries.contains { ($0.record.fullChargeCapacityMah ?? 0) > 0 }
        case .cycleCount:
            !entries.isEmpty
        }
    }

    private func primaryYValue(for record: BatteryHealthRecord) -> Double? {
        switch metric {
        case .healthPercent:
            record.systemHealthPercent ?? record.capacityRatioPercent
        case .capacityMah:
            record.fullChargeCapacityMah.map(Double.init)
        case .cycleCount:
            Double(record.cycleCount)
        }
    }

    private func chartXDomain(for entries: [PlotEntry]) -> ClosedRange<Date> {
        guard let first = entries.first?.date, let last = entries.last?.date else {
            let now = Date()
            return now.addingTimeInterval(-86_400)...now
        }
        if last <= first {
            return first.addingTimeInterval(-86_400)...first.addingTimeInterval(86_400)
        }
        return first...last
    }

    private func chartYDomain(for filtered: [BatteryHealthRecord]) -> ClosedRange<Double> {
        switch metric {
        case .healthPercent:
            BatteryHealthTrendAnalysis.healthPercentDomain(filtered)
        case .capacityMah:
            BatteryHealthTrendAnalysis.capacityDomain(filtered)
        case .cycleCount:
            BatteryHealthTrendAnalysis.cycleDomain(filtered)
        }
    }

    private func xAxisLabel(for date: Date, spanDays: Int) -> String {
        ProductDateFormatting.string(
            from: date,
            format: spanDays > 300 ? "yy/M" : "M/d",
            timeZone: calendar.timeZone,
            localeIdentifier: "zh_CN"
        )
    }

    private func yAxisLabel(for value: Double) -> String {
        switch metric {
        case .healthPercent:
            String(format: "%.0f%%", value)
        case .capacityMah:
            "\(Int(value.rounded())) mAh"
        case .cycleCount:
            "\(Int(value.rounded())) 次"
        }
    }

    private func closestEntry(to date: Date, in entries: [PlotEntry]) -> PlotEntry? {
        entries.min {
            abs($0.date.timeIntervalSince(date)) < abs($1.date.timeIntervalSince(date))
        }
    }
}
