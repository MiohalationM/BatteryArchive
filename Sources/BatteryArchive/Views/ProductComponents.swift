import SwiftUI

struct ProductPageTitle: View {
    let title: String
    let subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(BBType.pageTitle)
                .foregroundStyle(Color.bbInk)
            Text(subtitle)
                .font(BBType.body)
                .foregroundStyle(.secondary)
        }
    }
}

struct ProductPageHeader<Accessory: View>: View {
    let title: String
    let subtitle: String
    var systemImage: String = "square.grid.2x2"
    var tint: Color = .bbBlue
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 12) {
                BrandSymbol(systemImage: systemImage, tint: tint, size: 38)
                ProductPageTitle(title: title, subtitle: subtitle)
            }
            Spacer(minLength: 12)
            accessory
        }
        .frame(minHeight: 48)
        .padding(.horizontal, BBDesign.pagePadding)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}

extension ProductPageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String, systemImage: String = "square.grid.2x2", tint: Color = .bbBlue) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.tint = tint
        self.accessory = EmptyView()
    }
}

struct ProductMetric: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let value: String
    var unit = ""
    var small = false
    var symbol: String? = nil
    var tint: Color = .bbBlue

    var body: some View {
        VStack(alignment: .leading, spacing: small ? 6 : 8) {
            HStack(spacing: 6) {
                if let symbol {
                    BrandSymbol(systemImage: symbol, tint: tint, size: small ? 20 : 24)
                }
                Text(title)
                    .font(BBType.captionMedium)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font((small ? BBType.metricSmall : BBType.metricLarge).monospacedDigit())
                    .foregroundStyle(Color.bbInk)
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : ProductMotion.reading, value: value)
                if !unit.isEmpty && value != "—" {
                    Text(unit)
                        .font(BBType.captionMedium)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

extension View {
    func productCard(
        padding: CGFloat = BBDesign.cardPadding,
        accent: Color = .clear,
        tier: BBSurfaceTier = .card
    ) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .productSurface(tier, tint: accent == .clear ? .bbBlue : accent)
    }
}

struct ProductSegment<Value: Hashable>: Identifiable {
    let value: Value
    let title: String
    var id: Value { value }

    init(_ value: Value, _ title: String) {
        self.value = value
        self.title = title
    }
}

private struct SegmentBoundsKey<Value: Hashable>: PreferenceKey {
    static var defaultValue: [Value: Anchor<CGRect>] { [:] }
    static func reduce(
        value: inout [Value: Anchor<CGRect>],
        nextValue: () -> [Value: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

/// 原生质感中性分段控制器：单实例常驻滑块跟手滑移 + 悬停微光跟踪，零闪烁且支持快速打断。
struct ProductSegmentedControl<Value: Hashable>: View {
    let title: String
    @Binding var selection: Value
    let options: [ProductSegment<Value>]
    var tint: Color = .bbBlue
    @FocusState private var focusedOption: Value?
    @State private var hoveredOption: Value?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection == option.value
                let isHovered = hoveredOption == option.value && !isSelected
                Button {
                    guard selection != option.value else { return }
                    withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                        selection = option.value
                    }
                } label: {
                    Text(option.title)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(isSelected ? Color.bbInk : (isHovered ? Color.bbInk.opacity(0.84) : Color.secondary))
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 10)
                        .frame(maxWidth: .infinity, minHeight: 26)
                        .contentShape(Rectangle())
                        .animation(reduceMotion ? nil : ProductMotion.selection, value: isSelected)
                        .animation(reduceMotion ? nil : ProductMotion.hover, value: isHovered)
                }
                .buttonStyle(ProductPressStyle())
                .anchorPreference(key: SegmentBoundsKey<Value>.self, value: .bounds) { [option.value: $0] }
                .onHover { hoveredOption = $0 ? option.value : (hoveredOption == option.value ? nil : hoveredOption) }
                .focused($focusedOption, equals: option.value)
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .backgroundPreferenceValue(SegmentBoundsKey<Value>.self) { anchors in
            GeometryReader { proxy in
                ZStack(alignment: .topLeading) {
                    if let hovered = hoveredOption, hovered != selection, let anchor = anchors[hovered] {
                        let rect = proxy[anchor]
                        RoundedRectangle(cornerRadius: 7.5, style: .continuous)
                            .fill(Color.primary.opacity(scheme == .dark ? 0.065 : 0.042))
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                            .transition(.opacity)
                    }

                    if let anchor = anchors[selection] {
                        let rect = proxy[anchor]
                        selectedPill
                            .frame(width: rect.width, height: rect.height)
                            .offset(x: rect.minX, y: rect.minY)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .animation(reduceMotion ? nil : ProductMotion.pillGlide, value: selection)
                .animation(reduceMotion ? nil : ProductMotion.hover, value: hoveredOption)
            }
        }
        .padding(3)
        .background(
            scheme == .dark ? Color.white.opacity(0.075) : Color.black.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .onMoveCommand { direction in
            guard let current = options.firstIndex(where: { $0.value == selection }) else { return }
            let delta = direction == .left ? -1 : direction == .right ? 1 : 0
            let next = current + delta
            guard delta != 0, options.indices.contains(next) else { return }
            withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                selection = options[next].value
            }
            focusedOption = selection
        }
    }

    private var selectedPill: some View {
        let pillShape = RoundedRectangle(cornerRadius: 7.5, style: .continuous)
        return pillShape
            .fill(scheme == .dark ? Color(red: 0.24, green: 0.25, blue: 0.28) : Color.white)
            .overlay {
                pillShape.strokeBorder(
                    scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.06),
                    lineWidth: 0.5
                )
            }
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.22 : 0.08), radius: 2, y: 1)
    }
}

struct HistoryDateNavigator: View {
    @Binding var date: Date
    @Binding var period: HistoryPeriod
    let first: Date
    let calendar: Calendar
    var allowsPeriods = true
    var tint: Color = .bbBlue
    @State private var calendarVisible = false
    @State private var datePillHovered = false
    @State private var jumpHovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme

    private var now: Date { Date() }
    private var interval: DateInterval {
        HistoryCalendar.bounds(
            period: period, selection: date, first: first, now: now, calendar: calendar
        )
    }
    private var isCurrent: Bool { period == .all || (now >= interval.start && now < interval.end) }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 14) {
                periodPicker
                Spacer(minLength: 10)
                navigation
            }
            VStack(alignment: .leading, spacing: 10) {
                periodPicker
                navigation
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .productSurface(.card, tint: tint, cornerRadius: 16)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
    }

    @ViewBuilder
    private var periodPicker: some View {
        if allowsPeriods {
            ProductSegmentedControl(
                title: "统计范围",
                selection: $period,
                options: HistoryPeriod.allCases.map { .init($0, $0.rawValue) },
                tint: tint
            )
            .frame(width: 176)
        } else {
            HStack(spacing: 7) {
                BrandSymbol(systemImage: "calendar", tint: tint, size: 24)
                Text("每日使用")
                    .font(BBType.bodyMedium)
                    .foregroundStyle(Color.bbInk)
            }
        }
    }

    private var navigation: some View {
        HStack(spacing: 8) {
            if period != .all {
                navIconButton(
                    systemImage: "chevron.left",
                    label: period == .month ? "上个月" : "前一天",
                    disabled: interval.start <= calendar.startOfDay(for: first)
                ) { move(-1) }
            }

            Button {
                if period != .all { calendarVisible.toggle() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "calendar")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Text(
                        HistoryCalendar.title(
                            period: period, selection: date, first: first, now: now, calendar: calendar
                        )
                    )
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(Color.bbInk)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : ProductMotion.reading, value: date)
                    if period != .all {
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .rotationEffect(.degrees(calendarVisible ? 180 : 0))
                            .animation(reduceMotion ? nil : ProductMotion.selection, value: calendarVisible)
                    }
                }
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .background(
                    Color.primary.opacity(
                        (datePillHovered || calendarVisible)
                            ? (scheme == .dark ? 0.11 : 0.075)
                            : (scheme == .dark ? 0.065 : 0.045)
                    ),
                    in: RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                )
                .animation(reduceMotion ? nil : ProductMotion.hover, value: datePillHovered)
            }
            .buttonStyle(ProductPressStyle())
            .onHover { datePillHovered = $0 && period != .all }
            .accessibilityLabel("选择日期")
            .disabled(period == .all)
            .popover(isPresented: $calendarVisible, arrowEdge: .bottom) {
                VStack(alignment: .leading, spacing: 12) {
                    Text(period == .month ? "选择月份中的任意一天" : "选择日期")
                        .font(BBType.sectionTitle)
                    DatePicker(
                        "记录日期",
                        selection: $date,
                        in: calendar.startOfDay(for: min(first, now))...now,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                    .labelsHidden()
                    .onChange(of: date) { calendarVisible = false }
                }
                .padding(18)
                .frame(width: 310)
            }

            if period == .all {
                StatusPillBadge(
                    text: "起自 \(ProductDateFormatting.string(from: first, format: "yyyy年M月d日", timeZone: calendar.timeZone, localeIdentifier: "zh_CN"))",
                    tint: tint
                )
                .transition(reduceMotion ? .identity : .opacity.combined(with: .scale(scale: 0.96)))
            }

            if period != .all {
                navIconButton(
                    systemImage: "chevron.right",
                    label: period == .month ? "下个月" : "后一天",
                    disabled: isCurrent
                ) { move(1) }

                Button {
                    withAnimation(reduceMotion ? nil : ProductMotion.selection) {
                        date = now
                    }
                } label: {
                    Text(period == .month ? "本月" : "今天")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(isCurrent ? Color.secondary.opacity(0.6) : Color.bbBlue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(
                            isCurrent
                                ? Color.primary.opacity(0.035)
                                : Color.bbBlue.opacity(jumpHovered ? 0.14 : 0.09),
                            in: RoundedRectangle(cornerRadius: 8.5, style: .continuous)
                        )
                        .animation(reduceMotion ? nil : ProductMotion.hover, value: jumpHovered)
                        .animation(reduceMotion ? nil : ProductMotion.selection, value: isCurrent)
                }
                .buttonStyle(ProductPressStyle())
                .onHover { jumpHovered = $0 && !isCurrent }
                .disabled(isCurrent)
            }
        }
        .animation(reduceMotion ? nil : ProductMotion.reveal, value: period)
    }

    private func navIconButton(
        systemImage: String,
        label: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        NavIconButton(
            systemImage: systemImage,
            label: label,
            tint: tint,
            disabled: disabled,
            action: action
        )
    }

    private struct NavIconButton: View {
        let systemImage: String
        let label: String
        let tint: Color
        let disabled: Bool
        let action: () -> Void
        @State private var hovered = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion
        @Environment(\.colorScheme) private var scheme

        private var hoverNudge: CGFloat {
            guard hovered, !disabled, !reduceMotion else { return 0 }
            if systemImage.contains("left") { return -1.5 }
            if systemImage.contains("right") { return 1.5 }
            return 0
        }

        var body: some View {
            Button(action: action) {
                Image(systemName: systemImage)
                    .font(.system(size: 11, weight: .semibold))
                    .offset(x: hoverNudge)
                    .frame(width: 28, height: 28)
                    .background(
                        Color.primary.opacity(
                            disabled ? 0.025 : (hovered ? (scheme == .dark ? 0.12 : 0.08) : (scheme == .dark ? 0.065 : 0.045))
                        ),
                        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                    )
                    .animation(reduceMotion ? nil : ProductMotion.hover, value: hovered)
            }
            .buttonStyle(ProductPressStyle())
            .foregroundStyle(disabled ? Color.secondary.opacity(0.42) : Color.bbInk)
            .disabled(disabled)
            .onHover { hovered = $0 && !disabled }
            .accessibilityLabel(label)
        }
    }

    private func move(_ offset: Int) {
        withAnimation(reduceMotion ? nil : ProductMotion.selection) {
            date = HistoryCalendar.move(
                offset, period: period, selection: date, first: first, now: now, calendar: calendar
            )
        }
    }
}

/// 电量条与可选系统充电上限刻度。仅在确认读取到有效电量与目标时绘制填充与标尺。
struct BatteryChargeGauge: View {
    let level: Double?
    let mode: PowerStatePresentation.Mode
    var targetPercent: Int? = nil
    var height: CGFloat = 10
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var clampedFraction: Double {
        guard let level, level.isFinite else { return 0 }
        return min(1, max(0, level / 100))
    }

    private var fillGradient: LinearGradient {
        switch mode {
        case .battery:
            if let level, level <= 20 {
                return LinearGradient(colors: [.red.opacity(0.88), .orange], startPoint: .leading, endPoint: .trailing)
            }
            return LinearGradient(colors: [.bbMint.opacity(0.90), .bbMint], startPoint: .leading, endPoint: .trailing)
        case .charging:
            return LinearGradient(colors: [.bbAmber.opacity(0.88), .bbAmber], startPoint: .leading, endPoint: .trailing)
        case .external:
            return LinearGradient(colors: [.bbBlue.opacity(0.88), .bbBlue], startPoint: .leading, endPoint: .trailing)
        case .unknown:
            return LinearGradient(colors: [.secondary.opacity(0.3)], startPoint: .leading, endPoint: .trailing)
        }
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let fillWidth: CGFloat = (level != nil && w > 0 && clampedFraction > 0)
                ? max(min(w, 2), w * clampedFraction)
                : 0
            ZStack(alignment: .leading) {
                // 外层 Capsule 统一裁切：左侧始终自然圆角，未满 100%（含 95%/80% 充电上限）右侧平齐直切贴合上限标尺，
                // 仅当真正充至 100% 顶满轨道时右侧才呈现完整圆角。
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07))

                    if fillWidth > 0 {
                        Rectangle()
                            .fill(fillGradient)
                            .frame(width: fillWidth)
                            .animation(reduceMotion ? nil : ProductMotion.reading, value: clampedFraction)
                            .animation(reduceMotion ? nil : ProductMotion.reading, value: mode)
                    }
                }
                .clipShape(Capsule())

                if let targetPercent, (10...99).contains(targetPercent), w > 8 {
                    let markerX = w * Double(targetPercent) / 100
                    Capsule()
                        .fill(Color.bbInk.opacity(0.76))
                        .frame(width: 2.25, height: height + 4)
                        .offset(x: min(max(2, markerX - 1.125), w - 4.25))
                        .animation(reduceMotion ? nil : ProductMotion.reading, value: targetPercent)
                }
            }
        }
        .frame(height: height)
        .accessibilityHidden(true)
    }
}

/// 满充容量与设计容量对比条（首次进入可见态一次性平滑描绘，遵循减少动态效果）。
struct CapacityComparisonBar: View {
    let maxCapacity: Int
    let designCapacity: Int
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isSectionActive) private var isSectionActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    private var ratio: Double {
        guard designCapacity > 0, maxCapacity > 0 else { return 0 }
        return min(1.0, Double(maxCapacity) / Double(designCapacity))
    }

    var body: some View {
        let effectiveRatio = (revealed || reduceMotion) ? ratio : 0
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("当前满充容量占比")
                    .font(BBType.captionMedium)
                    .foregroundStyle(.secondary)
                Spacer()
                Text(designCapacity > 0 && maxCapacity > 0 ? String(format: "%.1f%%", ratio * 100) : "—")
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.bbInk)
                    .contentTransition(.numericText())
                    .animation(reduceMotion ? nil : ProductMotion.reading, value: ratio)
            }
            GeometryReader { geo in
                let fillWidth: CGFloat = effectiveRatio > 0
                    ? max(min(geo.size.width, 2), geo.size.width * effectiveRatio)
                    : 0
                ZStack(alignment: .leading) {
                    Rectangle()
                        .fill(scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07))
                    if fillWidth > 0 {
                        Rectangle()
                            .fill(Color.bbMint)
                            .frame(width: fillWidth)
                            .animation(reduceMotion ? nil : ProductMotion.reading, value: effectiveRatio)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 8)
            HStack {
                Text("当前满充 \(maxCapacity > 0 ? "\(maxCapacity) mAh" : "—")")
                Spacer()
                Text("出厂设计 \(designCapacity > 0 ? "\(designCapacity) mAh" : "—")")
            }
            .font(BBType.caption.monospacedDigit())
            .foregroundStyle(.secondary)
        }
        .productWell(tint: .bbMint, padding: 12)
        .onChange(of: isSectionActive, initial: true) { _, active in
            guard active, !revealed else { return }
            withAnimation(reduceMotion ? nil : ProductMotion.orbit) {
                revealed = true
            }
        }
    }
}

/// 规范对齐的键值内嵌数据槽，替代左对齐挤在一起的 LabeledContent。
struct MetricWellCell: View {
    let title: String
    let value: String
    var systemImage: String? = nil
    var tint: Color = .bbBlue

    var body: some View {
        HStack(spacing: 10) {
            if let systemImage {
                BrandSymbol(systemImage: systemImage, tint: tint, size: 24)
            }
            Text(title)
                .font(BBType.captionMedium)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.system(size: 12.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.bbInk)
        }
        .productWell(tint: tint, padding: 11)
        .accessibilityElement(children: .combine)
    }
}
