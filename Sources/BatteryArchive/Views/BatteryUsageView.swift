import SwiftUI
import Charts

private struct DayFooterBoundsKey: PreferenceKey {
    static var defaultValue: [Date: Anchor<CGRect>] { [:] }
    static func reduce(
        value: inout [Date: Anchor<CGRect>],
        nextValue: () -> [Date: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 电池分区：使用（离电日记录与明细）| 健康（电池健康面板）。
struct BatteryUsageView: View {
    @Environment(UsageReportModel.self) private var reports
    @Environment(ProductNavigation.self) private var navigation
    @Environment(\.isSectionActive) private var isSectionActive
    @State private var selectedDate = Date()
    @State private var followingToday = true
    @State private var detail: UsageDayReview?
    @State private var isLoading = true
    @State private var showAllSessions = false
    @State private var hoveredDay: Date?
    @State private var dailyPlotLeadingInset: CGFloat = 52
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var dailySummaries: [UsageDailySummary] { reports.summaries }
    private var historyError: String? { reports.error }
    private var firstRecordedAt: Date { reports.firstRecord }
    private var timeZoneID: String { reports.timeZoneID }
    private var availableTimeZones: [String] { reports.timeZones }

    private var showHealth: Binding<Bool> {
        Binding(
            get: { navigation.batteryHealth },
            set: { navigation.batteryHealth = $0 }
        )
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return value
    }

    private var today: Date { calendar.startOfDay(for: Date()) }
    private var window: UsageDateWindow {
        UsageDateWindow(
            firstRecordedAt: firstRecordedAt,
            selectedDate: selectedDate,
            now: Date(),
            calendar: calendar,
            retentionDays: nil
        )
    }
    private var earliest: Date { window.firstDay }
    private var selectedDay: Date { window.selectedDay }
    private var days: [Date] { window.days }
    private var selectedReview: UsageDayReview? {
        if detail?.date == selectedDay { return detail }
        if let todayReport = reports.today, todayReport.date == selectedDay { return todayReport }
        return nil
    }
    private var queryKey: String { "\(selectedDay.timeIntervalSince1970):\(timeZoneID):\(reports.revision)" }

    private var reviews: [UsageDayReview] {
        let grouped = Dictionary(grouping: dailySummaries, by: \.date)
        let now = Date()
        return days.map { date in
            let end = calendar.dateInterval(of: .day, for: date)?.end
                ?? calendar.date(byAdding: .day, value: 1, to: date)!
            var result = UsageDayReview(
                date: date,
                end: end,
                elapsedSeconds: max(0, min(now, end).timeIntervalSince(date))
            )
            if let matching = grouped[date] {
                result.apply(matching)
            }
            return result
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductPageHeader(
                title: "电池",
                subtitle: "离电使用与电池健康",
                systemImage: "battery.75percent",
                tint: .bbMint
            ) {
                ProductSegmentedControl(
                    title: "页面",
                    selection: showHealth,
                    options: [
                        .init(false, "使用"),
                        .init(true, "健康"),
                    ],
                    tint: .bbBlue
                )
                .frame(width: 196)
            }

            let isAlt = showHealth.wrappedValue
            ZStack(alignment: .topLeading) {
                if isAlt {
                    BatteryHealthPanel()
                        .environment(\.isSectionActive, isSectionActive)
                        .transition(reduceMotion ? .identity : .opacity)
                } else {
                    historyContent
                        .environment(\.isSectionActive, isSectionActive)
                        .transition(reduceMotion ? .identity : .opacity)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(reduceMotion ? nil : ProductMotion.page, value: isAlt)
        }
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
    }

    private var historyContent: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                HistoryDateNavigator(
                    date: $selectedDate,
                    period: .constant(.day),
                    first: firstRecordedAt,
                    calendar: calendar,
                    allowsPeriods: false
                )

                dailyChart

                if let historyError {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                        Text(historyError).font(BBType.body)
                    }
                    .foregroundStyle(.orange)
                    .productWell(tint: .orange)
                }

                if isLoading && selectedReview == nil && reviews.isEmpty {
                    ProgressView("读取使用记录…")
                        .frame(maxWidth: .infinity, minHeight: 180)
                        .productCard()
                } else if let day = selectedReview {
                    dayContent(day)
                }
            }
            .padding(.horizontal, BBDesign.pagePadding)
            .padding(.bottom, 28)
            .frame(maxWidth: BBDesign.contentMaxWidth)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .productScrollEdges()
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .task(id: queryKey) { await reload() }
        .onChange(of: selectedDate) { _, newDate in
            showAllSessions = false
            followingToday = calendar.isDate(newDate, inSameDayAs: today)
        }
        .onChange(of: reports.revision) { _, _ in
            if followingToday, !calendar.isDate(selectedDate, inSameDayAs: today) {
                selectedDate = today
            }
        }
        .onChange(of: timeZoneID) {
            selectedDate = today
            followingToday = true
        }
        .onAppear {
            if followingToday, !calendar.isDate(selectedDate, inSameDayAs: today) {
                selectedDate = today
            }
        }
    }

    private var maximumDailySeconds: Double {
        max(3_600, ceil((reviews.map(\.batterySeconds).max() ?? 0) / 3_600) * 3_600)
    }

    // MARK: - 日视图 7 天 Swift Charts 柱图（统一样式 + 点击/悬停/键盘选日）

    private var dailyChart: some View {
        let entries = reviews
        let reviewByDate = Dictionary(uniqueKeysWithValues: entries.map { ($0.date, $0) })
        let maxY = maximumDailySeconds
        let midY = maxY / 2

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(
                title: "每日离电使用",
                systemImage: "battery.75percent",
                tint: .bbMint
            ) {
                HStack(spacing: 12) {
                    key("亮屏", color: .bbMint)
                    key("息屏", color: .bbSlateBlue)
                }
            }

            Chart {
                ForEach(0..<7, id: \.self) { index in
                    let slot = String(index)
                    let dayDate = index < days.count ? days[index] : nil
                    let review: UsageDayReview? = dayDate.flatMap { reviewByDate[$0] }
                    let isSelected = dayDate == selectedDay
                    let isHovered = dayDate != nil && hoveredDay == dayDate

                    if let review, review.hasEvidence, review.batterySeconds > 0 {
                        let hasOff = review.screenOffSeconds > 0
                        if review.screenOnSeconds > 0 {
                            BarMark(
                                x: .value("日期", slot),
                                y: .value("亮屏", review.screenOnSeconds),
                                width: .fixed(26)
                            )
                            .foregroundStyle(Color.bbMint)
                            .opacity(isSelected ? 1.0 : (isHovered ? 0.85 : 0.65))
                            .cornerRadius(hasOff ? 0 : 5)
                        }
                        if hasOff {
                            BarMark(
                                x: .value("日期", slot),
                                y: .value("息屏", review.screenOffSeconds),
                                width: .fixed(26)
                            )
                            .foregroundStyle(Color.bbSlateBlue)
                            .opacity(isSelected ? 0.92 : (isHovered ? 0.75 : 0.55))
                            .cornerRadius(5)
                        }
                    }
                }
            }
            .chartXScale(domain: (0..<7).map(String.init))
            .chartYScale(domain: 0...maxY)
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, midY, maxY]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(duration(v))
                                .font(.system(size: 10, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                                .frame(width: 44, alignment: .trailing)
                        }
                    }
                }
            }
            .chartBackground { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let plot = geometry[anchor]
                        let colSpacing: CGFloat = 4
                        let colWidth = max(0, (plot.width - colSpacing * 6) / 7)
                        let selectedIndex = days.firstIndex(of: selectedDay)
                        let hoveredIndex = hoveredDay.flatMap { d in
                            d == selectedDay ? nil : days.firstIndex(of: d)
                        }

                        ZStack(alignment: .topLeading) {
                            if let hoveredIndex {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.bbMint.opacity(0.055))
                                    .frame(width: colWidth, height: plot.height)
                                    .offset(x: CGFloat(hoveredIndex) * (colWidth + colSpacing), y: 0)
                                    .transition(.opacity)
                            }
                            if let selectedIndex {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.bbMint.opacity(0.11))
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.bbMint.opacity(0.30), lineWidth: 0.9)
                                    }
                                    .frame(width: colWidth, height: plot.height)
                                    .offset(x: CGFloat(selectedIndex) * (colWidth + colSpacing), y: 0)
                            }
                        }
                        .frame(width: plot.width, height: plot.height, alignment: .topLeading)
                        .position(x: plot.midX, y: plot.midY)
                        .animation(reduceMotion ? nil : ProductMotion.pillGlide, value: selectedIndex)
                        .animation(reduceMotion ? nil : ProductMotion.hover, value: hoveredIndex)
                        .onAppear { syncPlotInset(plot.minX) }
                        .onChange(of: plot.minX) { _, newX in syncPlotInset(newX) }
                    }
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let anchor = proxy.plotFrame {
                        let plot = geometry[anchor]
                        HStack(spacing: 4) {
                            ForEach(0..<7, id: \.self) { index in
                                if index < days.count {
                                    let date = days[index]
                                    let review = reviewByDate[date]
                                    dayColumnHitButton(date: date, review: review)
                                } else {
                                    Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                        }
                        .frame(width: plot.width, height: plot.height)
                        .position(x: plot.midX, y: plot.midY)
                    }
                }
            }
            .frame(height: 154)
            .chartSurface()

            // 日期与数值底标与真实绘图区左侧动态对齐（单实例跟手滑块）
            HStack(spacing: 0) {
                Color.clear.frame(width: max(0, dailyPlotLeadingInset), height: 1)
                HStack(spacing: 4) {
                    ForEach(0..<7, id: \.self) { index in
                        if index < days.count {
                            let date = days[index]
                            let review = reviewByDate[date]
                            dayFooterLabel(date: date, review: review)
                        } else {
                            Color.clear.frame(maxWidth: .infinity)
                        }
                    }
                }
                .backgroundPreferenceValue(DayFooterBoundsKey.self) { anchors in
                    GeometryReader { proxy in
                        ZStack(alignment: .topLeading) {
                            if let hovered = hoveredDay, hovered != selectedDay, let anchor = anchors[hovered] {
                                let rect = proxy[anchor]
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.bbBlue.opacity(0.06))
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                                    .transition(.opacity)
                            }
                            if let anchor = anchors[selectedDay] {
                                let rect = proxy[anchor]
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .fill(Color.bbBlue.opacity(0.12))
                                    .frame(width: rect.width, height: rect.height)
                                    .offset(x: rect.minX, y: rect.minY)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .animation(reduceMotion ? nil : ProductMotion.pillGlide, value: selectedDay)
                        .animation(reduceMotion ? nil : ProductMotion.hover, value: hoveredDay)
                    }
                }
            }

            Text("薄荷绿为离电亮屏，灰蓝为离电息屏；休眠与未记录时间不计入柱高。")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
        }
        .productCard(accent: .bbMint)
    }

    private func syncPlotInset(_ minX: CGFloat) {
        let adjusted = minX + 2 // 计入 chartSurface() 的 2pt 水平内边距
        if abs(adjusted - dailyPlotLeadingInset) > 0.5 {
            dailyPlotLeadingInset = adjusted
        }
    }

    private func dayColumnHitButton(date: Date, review: UsageDayReview?) -> some View {
        let selected = date == selectedDay
        let valid = date >= earliest && date <= today
        return Button {
            withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                selectedDate = date
            }
        } label: {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!valid)
        .onHover { isHovering in
            guard valid else { return }
            if isHovering {
                hoveredDay = date
            } else if hoveredDay == date {
                hoveredDay = nil
            }
        }
        .help(
            review?.hasEvidence == true
                ? "\(dateLabel(date, format: "M月d日"))：离电亮屏 \(duration(review?.screenOnSeconds ?? 0))；离电息屏 \(duration(review?.screenOffSeconds ?? 0))"
                : "\(dateLabel(date, format: "M月d日"))：未记录"
        )
        .accessibilityLabel(
            "\(dateLabel(date, format: "M月d日"))，\(review?.hasEvidence == true ? "离电\(duration(review?.batterySeconds ?? 0))" : "未记录")"
        )
        .accessibilityValue(selected ? "已选中" : "")
        .onMoveCommand { direction in
            let delta = direction == .left ? -1 : direction == .right ? 1 : 0
            if delta != 0,
               let next = calendar.date(byAdding: .day, value: delta, to: selectedDay),
               next >= earliest, next <= today
            {
                withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                    selectedDate = next
                }
            }
        }
    }

    private func dayFooterLabel(date: Date, review: UsageDayReview?) -> some View {
        let selected = date == selectedDay
        let valid = date >= earliest && date <= today
        let valueText = review?.hasEvidence == true ? duration(review?.batterySeconds ?? 0) : "未记录"

        return Button {
            guard valid else { return }
            withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                selectedDate = date
            }
        } label: {
            VStack(spacing: 3) {
                Text(date, format: .dateTime.month().day())
                    .font(.system(size: 11, weight: selected ? .semibold : .medium))
                    .foregroundStyle(selected ? Color.bbBlue : Color.bbInk)
                Text(valueText)
                    .font(.system(size: 10.5, weight: selected ? .semibold : .regular, design: .rounded).monospacedDigit())
                    .foregroundStyle(valueText == "未记录" ? AnyShapeStyle(.tertiary) : AnyShapeStyle(.secondary))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 5)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .animation(reduceMotion ? nil : ProductMotion.selection, value: selected)
        }
        .buttonStyle(ProductPressStyle())
        .anchorPreference(key: DayFooterBoundsKey.self, value: .bounds) { [date: $0] }
        .onHover { isHovering in
            guard valid else { return }
            if isHovering {
                hoveredDay = date
            } else if hoveredDay == date {
                hoveredDay = nil
            }
        }
    }

    // MARK: - 选中日模块化卡片组

    @ViewBuilder
    private func dayContent(_ day: UsageDayReview) -> some View {
        VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
            dayOverviewCard(day)
            if day.hasEvidence && day.hasDetailedRecords {
                sessionListCard(day)
            }
            if day.hasEvidence {
                diagnosticsCard(day)
            }
        }
    }

    private func dayOverviewCard(_ day: UsageDayReview) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 10) {
                BrandSymbol(
                    systemImage: "battery.100percent",
                    tint: .bbMint,
                    size: 28
                )
                Text(day.date, format: .dateTime.month().day().weekday(.wide))
                    .font(.system(size: 17, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.bbInk)
                Spacer()
                if day.hasEvidence {
                    StatusPillBadge(
                        text: "已记录 \(duration(day.knownSeconds))",
                        tint: .bbBlue
                    )
                }
            }

            if !day.hasEvidence {
                VStack(alignment: .leading, spacing: 10) {
                    Text(calendar.isDate(day.date, inSameDayAs: today) ? "正在积累使用记录" : "这一天没有可用的使用记录")
                        .font(BBType.sectionTitle)
                        .foregroundStyle(Color.bbInk)
                    Text("开始记录后，这里会展示离电使用时长与电量变化。几分钟的短暂离电也会累计。")
                        .font(BBType.body)
                        .foregroundStyle(.secondary)
                    Text("未记录时段不会计入离电时长。")
                        .font(BBType.caption)
                        .foregroundStyle(.secondary)
                    timeZoneControl
                }
                .productWell(tint: .bbBlue, padding: 14)
            } else {
                dayMetrics(day)
                if day.hasDetailedRecords {
                    UsageDayTimeline(day: day)
                } else {
                    Text("详细曲线已过 30 天保留期，日使用汇总仍然保留。")
                        .font(BBType.body)
                        .foregroundStyle(.secondary)
                        .productWell(tint: .bbBlue, padding: 12)
                }
                HStack(spacing: 8) {
                    StatusPillBadge(text: "休眠 \(duration(day.sleepSeconds))", tint: .bbPurple)
                    StatusPillBadge(text: "未记录 \(duration(day.unknownSeconds))", tint: .secondary)
                    Spacer()
                }
            }
        }
        .productCard(accent: .bbMint)
    }

    private func dayMetrics(_ day: UsageDayReview) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) { dayMetricTiles(day) }
                .fixedSize(horizontal: false, vertical: true)
            if let coverage = day.powerCoverage {
                if coverage < 0.9 {
                    StatusPillBadge(
                        text: "部分时段缺少功率数据",
                        tint: .bbAmber
                    )
                }
            } else {
                StatusPillBadge(
                    text: "当天尚无离电使用记录",
                    tint: .secondary
                )
            }
        }
    }

    @ViewBuilder
    private func dayMetricTiles(_ day: UsageDayReview) -> some View {
        StatTile(icon: "sun.max.fill", tint: .bbMint, value: duration(day.screenOnSeconds), unit: "", label: "离电亮屏")
        StatTile(icon: "moon.zzz.fill", tint: .bbSlateBlue, value: duration(day.screenOffSeconds), unit: "", label: "离电息屏")
        StatTile(
            icon: "bolt.circle.fill",
            tint: .bbBlue,
            value: day.powerSeconds > 0
                ? String(format: "%.1f", day.dischargeWh * 3_600 / day.powerSeconds)
                : (day.batterySeconds > 0 ? "采样不足" : "—"),
            unit: day.powerSeconds > 0 ? "W" : "",
            label: "平均离电功耗"
        )
    }

    private func sessionListCard(_ day: UsageDayReview) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(
                title: day.canRankSessions ? "主要离电时段" : "当天离电时段",
                systemImage: "list.bullet.rectangle.portrait.fill",
                tint: .bbMint
            ) {
                if day.sessions.count > 1 && day.canRankSessions {
                    StatusPillBadge(text: "按耗电排序", tint: .bbMint)
                }
            }

            if day.sessions.isEmpty {
                Text("尚无离电使用；下次拔电后会开始记录，不需要等到电量下降 1%。")
                    .font(BBType.body)
                    .foregroundStyle(.secondary)
                    .productWell(tint: .bbMint, padding: 12)
            } else {
                let displayed = showAllSessions ? day.displaySessions : Array(day.displaySessions.prefix(3))
                VStack(spacing: 8) {
                    ForEach(displayed) { session in
                        UsageSessionRow(session: session, timeZone: calendar.timeZone)
                            .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                    }
                }
                .clipped()
                .animation(reduceMotion ? nil : ProductMotion.reveal, value: showAllSessions)
                if day.sessions.count > 3 {
                    Button {
                        withAnimation(reduceMotion ? nil : ProductMotion.reveal) {
                            showAllSessions.toggle()
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "chevron.down")
                                .font(.system(size: 10, weight: .semibold))
                                .rotationEffect(.degrees(showAllSessions ? 180 : 0))
                                .animation(reduceMotion ? nil : ProductMotion.selection, value: showAllSessions)
                            Text(showAllSessions ? "收起其他时段" : "查看当天全部 \(day.sessions.count) 个时段")
                                .font(BBType.captionMedium)
                        }
                        .foregroundStyle(Color.bbBlue)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.bbBlue.opacity(0.09), in: Capsule())
                    }
                    .buttonStyle(ProductPressStyle())
                }
            }
        }
        .productCard(accent: .bbMint)
    }

    private func diagnosticsCard(_ day: UsageDayReview) -> some View {
        let dischargeSummary: String = if day.batterySeconds > 0 {
            "有效 \(duration(day.powerSeconds)) / \(duration(day.batterySeconds))（覆盖 \(Int(((day.powerCoverage ?? 0) * 100).rounded()))%）"
                + (day.powerSeconds > 0 ? String(format: " · 累计 %.2f Wh", day.dischargeWh) : "")
                + (day.estimatedSeconds > 0 ? " · 估算来源 \(duration(day.estimatedSeconds))" : "")
        } else {
            "当天暂无离电采样"
        }
        var gapParts: [String] = [
            "已确认休眠 \(duration(day.sleepSeconds))",
            "未运行/其他 \(duration(day.unrecordedSeconds))",
        ]
        if day.samplingGapSeconds > 0 {
            gapParts.append("采样超时 \(duration(day.samplingGapSeconds))")
        }
        if day.readFailureSeconds > 0 {
            gapParts.append("读取失败 \(duration(day.readFailureSeconds))")
        }
        if day.clockRollbackCount > 0 {
            gapParts.append("时钟回拨 \(day.clockRollbackCount) 次")
        }

        return ProductDisclosure("采样与缺口") {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 6) {
                    diagnosticRow("离电放电采样", dischargeSummary)
                    Divider().opacity(0.3)
                    diagnosticRow("休眠与缺口", gapParts.joined(separator: " · "))
                }
                .productWell(tint: .bbBlue, padding: 10)

                if day.skippedLines > 0 {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.bbAmber)
                        Text("历史日志中有 \(day.skippedLines) 条损坏行已安全跳过，其余记录正常保留。")
                            .foregroundStyle(Color.bbAmber)
                    }
                }
                if day.detailsTruncated {
                    Text("部分高频事件的明细已压缩，累计时长和能量完整保留。")
                        .foregroundStyle(Color.bbAmber)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("来源：放电量按电池功率与持续时长累计，由电压电流换算的来源标为估算。")
                    Text("口径：亮屏表示显示器开启，不等同实际操作；息屏、休眠与缺口分别统计，不估补缺失能量。")
                    Text("保留：日使用汇总与电池健康记录长期保存在本机，5 分钟使用明细保留 30 天；功耗页分钟采样保留 24 小时。")
                }
                timeZoneControl
            }
            .font(BBType.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.horizontal, 4)
        }
        .productCard(padding: 13, accent: .bbBlue)
    }

    private func diagnosticRow(_ label: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(BBType.captionMedium)
                .foregroundStyle(.secondary)
                .frame(width: 82, alignment: .leading)
            Text(value)
                .font(BBType.caption.monospacedDigit())
                .foregroundStyle(Color.bbInk)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var timeZoneControl: some View {
        if Set(availableTimeZones + [timeZoneID]).count > 1 {
            Picker(
                "记录时区",
                selection: Binding(get: { reports.timeZoneID }, set: { reports.timeZoneID = $0 })
            ) {
                ForEach(Array(Set(availableTimeZones + [timeZoneID])).sorted(), id: \.self) { id in
                    Text(id).tag(id)
                }
            }
            .fixedSize()
        } else {
            Text("记录时区：\(timeZoneID)")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func key(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2.5).fill(color).frame(width: 9, height: 9)
            Text(title).font(BBType.captionMedium).foregroundStyle(.secondary)
        }
    }

    private func reload() async {
        let date = selectedDay
        let result = await reports.detail(for: date)
        guard !Task.isCancelled else { return }
        detail = result
        isLoading = false
    }

    private func duration(_ seconds: TimeInterval) -> String { UsageTimeFormat.duration(seconds) }
    private func dateLabel(_ date: Date, format: String) -> String {
        ProductDateFormatting.string(from: date, format: format, timeZone: calendar.timeZone)
    }
}

struct UsageDayTimeline: View {
    let day: UsageDayReview
    @State private var selectedTime: Date?

    init(day: UsageDayReview, selectedTime: Date? = nil) {
        self.day = day
        _selectedTime = State(initialValue: selectedTime)
    }

    private var nearest: UsagePlotPoint? {
        guard let selectedTime else { return nil }
        return day.levels.min {
            abs($0.date.timeIntervalSince(selectedTime)) < abs($1.date.timeIntervalSince(selectedTime))
        }
    }

    private var levelSegments: [[UsagePlotPoint]] {
        var groups: [[UsagePlotPoint]] = []
        var current: [UsagePlotPoint] = []
        for point in day.levels {
            if let last = current.last, last.segment != point.segment {
                groups.append(current)
                current = []
            }
            current.append(point)
        }
        if !current.isEmpty { groups.append(current) }
        return groups
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text("电量与电源")
                        .font(BBType.cardTitle)
                        .foregroundStyle(Color.bbInk)
                    Spacer()
                    legendStrip
                }
                VStack(alignment: .leading, spacing: 6) {
                    Text("电量与电源")
                        .font(BBType.cardTitle)
                        .foregroundStyle(Color.bbInk)
                    legendStrip
                }
            }

            Chart {
                ForEach(Array(levelSegments.enumerated()), id: \.offset) { _, segment in
                    ForEach(segment) { point in
                        AreaMark(
                            x: .value("时间", point.date),
                            yStart: .value("基线", 0),
                            yEnd: .value("电量", point.level),
                            series: .value("连续区间", point.segment)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [Color.bbMint.opacity(0.18), Color.bbMint.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        LineMark(
                            x: .value("时间", point.date),
                            y: .value("电量", point.level),
                            series: .value("连续区间", point.segment)
                        )
                        .foregroundStyle(Color.bbMint)
                        .interpolationMethod(.linear)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                        PointMark(x: .value("时间", point.date), y: .value("电量", point.level))
                            .foregroundStyle(Color.bbMint)
                            .symbolSize(6)
                    }
                }

                if let nearest, selectedTime != nil {
                    RuleMark(x: .value("读取时间", nearest.date))
                        .foregroundStyle(Color.bbMint.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3]))
                    PointMark(x: .value("读取时间", nearest.date), y: .value("电量", nearest.level))
                        .foregroundStyle(Color.bbMint.opacity(0.24))
                        .symbolSize(140)
                    PointMark(x: .value("读取时间", nearest.date), y: .value("电量", nearest.level))
                        .foregroundStyle(Color.bbMint)
                        .symbolSize(44)
                }
            }
            .chartXSelection(value: $selectedTime)
            .chartXScale(domain: day.date...day.end, range: .plotDimension(padding: 4))
            .chartYScale(domain: 0...100, range: .plotDimension(padding: 4))
            .chartXAxis(.hidden)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0, 50, 100]) { value in
                    AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5, dash: [3]))
                        .foregroundStyle(.quaternary)
                    AxisValueLabel {
                        if let level = value.as(Int.self) {
                            Text("\(level)%")
                                .font(.system(size: 10, design: .rounded).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartPlotStyle { $0.clipped() }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    if let nearest, let anchor = proxy.plotFrame {
                        let plot = geometry[anchor]
                        let x = plot.minX + (proxy.position(forX: nearest.date) ?? 0)
                        let y = plot.minY + (proxy.position(forY: nearest.level) ?? 0)
                        let activity = activity(at: nearest.date)
                        VStack(alignment: .leading, spacing: 2.5) {
                            HStack(spacing: 5) {
                                Text(nearest.date, format: .dateTime.hour().minute())
                                    .font(BBType.micro.monospacedDigit())
                                    .foregroundStyle(.secondary)
                                if let activity {
                                    HStack(spacing: 3) {
                                        Circle()
                                            .fill(color(activity))
                                            .frame(width: 5, height: 5)
                                        Text(activityLabel(activity))
                                            .font(BBType.micro)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            Text("\(BatteryLevelPresentation.percent(nearest.level))%")
                                .font(.system(size: 12.5, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color.bbInk)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .fixedSize()
                        .productSurface(.card, tint: .bbMint, cornerRadius: 10)
                        .position(
                            x: min(max(x, plot.minX + 50), plot.maxX - 50),
                            y: min(max(y - 34, plot.minY + 26), plot.maxY - 26)
                        )
                        .allowsHitTesting(false)
                    }
                }
            }
            .frame(height: 154)

            Chart {
                RectangleMark(
                    xStart: .value("起始", day.date),
                    xEnd: .value("结束", day.end),
                    yStart: .value("状态", 0.28),
                    yEnd: .value("状态", 0.72)
                )
                .foregroundStyle(Color.secondary.opacity(0.08))
                .cornerRadius(4)

                ForEach(day.spans) { span in
                    RectangleMark(
                        xStart: .value("起始", span.start),
                        xEnd: .value("结束", span.end),
                        yStart: .value("状态", 0.28),
                        yEnd: .value("状态", 0.72)
                    )
                    .foregroundStyle(color(span.activity))
                }

                if let nearest, selectedTime != nil {
                    RuleMark(x: .value("读取时间", nearest.date))
                        .foregroundStyle(Color.bbMint.opacity(0.65))
                        .lineStyle(StrokeStyle(lineWidth: 1.25))
                }
            }
            .chartXScale(domain: day.date...day.end, range: .plotDimension(padding: 4))
            .chartYScale(domain: 0...1)
            .chartYAxis {
                AxisMarks(position: .leading, values: [0.5]) { _ in
                    AxisValueLabel {
                        Text("100%")
                            .font(.system(size: 10, design: .rounded).monospacedDigit())
                            .hidden()
                    }
                }
            }
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { value in
                    let atEnd = value.as(Date.self).map { $0 >= day.end } ?? false
                    AxisValueLabel {
                        if atEnd {
                            Text("24:00").font(BBType.micro).foregroundStyle(.secondary)
                        } else if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour().minute()).font(BBType.micro).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartPlotStyle { $0.clipped() }
            .frame(height: 44)
            .accessibilityLabel("当天电源状态，空白表示没有记录")

            if day.levels.isEmpty {
                Text("电量读数暂缺，已记录的使用时长仍会保留。")
                    .font(BBType.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .onChange(of: day.date) { selectedTime = nil }
    }

    private var legendStrip: some View {
        HStack(spacing: 10) {
            legend(.batteryScreenOn, "亮屏")
            legend(.batteryScreenOff, "息屏")
            legend(.onPower, "接电")
            legend(.sleep, "休眠")
            legend(.unknown, "未记录")
        }
    }

    private func color(_ activity: UsageActivity) -> Color {
        switch activity {
        case .batteryScreenOn: .bbMint
        case .batteryScreenOff: .bbSlateBlue
        case .onPower: .bbBlue.opacity(0.32)
        case .sleep: .bbPurple.opacity(0.55)
        case .unknown: .secondary.opacity(0.10)
        }
    }

    private func activity(at date: Date) -> UsageActivity? {
        if let exact = day.spans.first(where: { date >= $0.start && date <= $0.end }) {
            return exact.activity
        }
        return nil
    }

    private func activityLabel(_ activity: UsageActivity) -> String {
        switch activity {
        case .batteryScreenOn: "亮屏"
        case .batteryScreenOff: "息屏"
        case .onPower: "接电"
        case .sleep: "休眠"
        case .unknown: "未记录"
        }
    }

    private func legend(_ activity: UsageActivity, _ name: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2).fill(color(activity)).frame(width: 8, height: 8)
            Text(name).font(BBType.micro).foregroundStyle(.secondary)
        }
    }
}

private struct UsageSessionRow: View {
    let session: UsageSessionSummary
    let timeZone: TimeZone
    @State private var expanded = false
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tint: Color = session.ongoing ? .bbBlue : .bbMint
        VStack(alignment: .leading, spacing: 8) {
            Button {
                withAnimation(reduceMotion ? nil : ProductMotion.reveal) {
                    expanded.toggle()
                }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text("\(time(session.start))–\(time(session.end))")
                                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                                .foregroundStyle(Color.bbInk)
                            if session.ongoing {
                                StatusPillBadge(text: "进行中", tint: .bbBlue, showDot: true)
                            }
                            if let start = session.startLevel, let end = session.endLevel {
                                Text("\(BatteryLevelPresentation.percent(start))% → \(BatteryLevelPresentation.percent(end))%")
                                    .font(.system(size: 11.5, weight: .medium, design: .rounded).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Text("亮屏 \(UsageTimeFormat.duration(session.screenOnSeconds)) · 息屏 \(UsageTimeFormat.duration(session.screenOffSeconds))")
                            .font(BBType.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        let endMissing = !session.ongoing && session.endIncomplete
                        if session.startIncomplete && endMissing {
                            StatusPillBadge(text: "起止未完整记录", tint: .bbAmber)
                        } else if session.startIncomplete {
                            StatusPillBadge(text: "开始未完整记录", tint: .bbAmber)
                        } else if endMissing {
                            StatusPillBadge(text: "结束未完整记录", tint: .secondary)
                        }
                    }

                    Spacer(minLength: 8)

                    VStack(alignment: .trailing, spacing: 3) {
                        Text(
                            session.powerSeconds > 0
                                ? String(format: "%.1f W", session.dischargeWh * 3_600 / session.powerSeconds)
                                : "功率暂缺"
                        )
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.bbInk)
                        HStack(spacing: 4) {
                            if session.estimatedSeconds > 0 {
                                StatusPillBadge(text: "含估算", tint: .bbAmber)
                            }
                            if session.coverage < 0.9 {
                                StatusPillBadge(text: "部分采样", tint: .secondary)
                            }
                        }
                    }

                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(expanded ? 180 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(ProductPressStyle())
            .onHover { hovered = $0 }
            .accessibilityValue(expanded ? "已展开" : "已收起")

            if expanded {
                VStack(alignment: .leading, spacing: 6) {
                    Divider().opacity(0.4)
                    HStack(spacing: 12) {
                        Label(
                            "功率覆盖 \(Int((session.coverage * 100).rounded()))%",
                            systemImage: "waveform.path.ecg"
                        )
                        if session.powerSeconds > 0 {
                            Label(
                                String(format: "累计放电 %.2f Wh", session.dischargeWh),
                                systemImage: "bolt"
                            )
                        }
                    }
                    .font(BBType.captionMedium.monospacedDigit())
                    .foregroundStyle(Color.bbInk.opacity(0.85))
                    if session.startIncomplete && !session.ongoing && session.endIncomplete {
                        Text("该时段起止均未观测到完整插拔边界（如启动、唤醒、休眠或采样缺口截断）。")
                            .font(BBType.caption)
                            .foregroundStyle(Color.bbAmber)
                    } else if session.startIncomplete {
                        Text("开始边界未完整记录（应用启动、唤醒或采样缺口时已在离电状态）。")
                            .font(BBType.caption)
                            .foregroundStyle(Color.bbAmber)
                    } else if !session.ongoing && session.endIncomplete {
                        Text("结束边界未完整记录（因休眠、采样缺口或应用退出提前截断）。")
                            .font(BBType.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .productWell(tint: tint, padding: 12)
        .brightness(hovered ? 0.02 : 0)
        .animation(reduceMotion ? nil : ProductMotion.hover, value: hovered)
    }

    private func time(_ date: Date) -> String {
        ProductDateFormatting.string(from: date, format: "HH:mm", timeZone: timeZone)
    }
}

enum UsageTimeFormat {
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite else { return "0m" }
        if seconds > 0 && seconds < 60 { return "<1m" }
        let total = max(0, Int(seconds))
        let minutes = total / 60
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}
