import SwiftUI

private struct SectionActiveEnvironmentKey: EnvironmentKey {
    static let defaultValue: Bool = true
}

extension EnvironmentValues {
    var isSectionActive: Bool {
        get { self[SectionActiveEnvironmentKey.self] }
        set { self[SectionActiveEnvironmentKey.self] = newValue }
    }
}

extension ProductSection {
    var title: String {
        switch self {
        case .overview: "概览"
        case .energy: "功耗"
        case .battery: "电池"
        case .settings: "设置"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .energy: "bolt"
        case .battery: "battery.75percent"
        case .settings: "gearshape"
        }
    }

    var selectedSystemImage: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .energy: "bolt.fill"
        case .battery: "battery.75percent"
        case .settings: "gearshape.fill"
        }
    }
}

struct MainWindowView: View {
    @Environment(PowerSampler.self) private var sampler
    @Environment(ProductNavigation.self) private var navigation
    @Environment(UsageReportModel.self) private var reports
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 按需懒加载并保留已访问过的页面，消除来回切换模块时重复销毁/重建图表与玻璃视图树的卡顿。
    @State private var mountedSections: Set<ProductSection> = []

    var body: some View {
        HStack(spacing: 0) {
            ProductSidebar(
                selection: Binding(get: { navigation.section }, set: { navigation.section = $0 })
            ) {
                SidebarBatteryStatus()
            }

            ZStack(alignment: .topLeading) {
                ForEach(ProductSection.allCases) { section in
                    let isActive = navigation.section == section
                    if mountedSections.contains(section) || isActive {
                        // 纯 GPU 图层位移 + 轻缩放 + 淡入淡出：方向与侧栏上下点击一致，预挂载下零布局重算、120fps 顺滑。
                        let directionalOffsetY: CGFloat = {
                            guard !reduceMotion, !isActive else { return 0 }
                            return section.rawValue < navigation.section.rawValue ? -10 : 10
                        }()
                        sectionView(for: section)
                            .environment(\.isSectionActive, isActive)
                            .opacity(isActive ? 1 : 0)
                            .offset(y: directionalOffsetY)
                            .scaleEffect(isActive || reduceMotion ? 1.0 : 0.994, anchor: .center)
                            .allowsHitTesting(isActive)
                            .accessibilityHidden(!isActive)
                            .zIndex(isActive ? 1 : 0)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .clipped()
            .animation(reduceMotion ? nil : ProductMotion.page, value: navigation.section)
        }
        .background { AppBackdrop() }
        .frame(minWidth: 840, minHeight: 580)
        .onAppear {
            mountedSections.insert(navigation.section)
        }
        .task {
            // 主窗口首帧稳定后按空闲步进预挂载其余三个分区（静默状态不触发刷新与动画），
            // 彻底消除首次点击「功耗 / 电池 / 设置」时同步构建 Swift Charts 导致的掉帧卡顿。
            try? await Task.sleep(for: .milliseconds(220))
            for section in ProductSection.allCases where !mountedSections.contains(section) {
                guard !Task.isCancelled else { return }
                mountedSections.insert(section)
                try? await Task.sleep(for: .milliseconds(70))
            }
        }
        .onChange(of: navigation.section) { _, newSection in
            mountedSections.insert(newSection)
        }
        .onChange(of: reports.timeZoneID) {
            Task { await reports.refresh(live: sampler.liveUsageBuckets()) }
        }
    }

    @ViewBuilder
    private func sectionView(for section: ProductSection) -> some View {
        switch section {
        case .overview: OverviewView()
        case .energy: PowerAnalysisView()
        case .battery: BatteryUsageView()
        case .settings: SettingsView()
        }
    }
}

private struct SidebarItemBoundsKey: PreferenceKey {
    static var defaultValue: [ProductSection: Anchor<CGRect>] { [:] }
    static func reduce(
        value: inout [ProductSection: Anchor<CGRect>],
        nextValue: () -> [ProductSection: Anchor<CGRect>]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

struct ProductSidebar<Status: View>: View {
    @Binding var selection: ProductSection
    @ViewBuilder var status: Status
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var hoveredSection: ProductSection?

    private var navShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: 11, style: .continuous)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 8.5, style: .continuous))
                    .shadow(color: Color.bbBlue.opacity(0.18), radius: 5, y: 2)
                VStack(alignment: .leading, spacing: 1) {
                    Text(AppBrand.displayName)
                        .font(.system(size: 13.5, weight: .bold, design: .rounded))
                        .foregroundStyle(Color.bbInk)
                        .lineLimit(1)
                    Text(AppBrand.tagline)
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 20)

            VStack(spacing: 4) {
                ForEach(ProductSection.allCases) { section in
                    let isSelected = selection == section
                    let isHovered = hoveredSection == section && !isSelected
                    Button {
                        guard selection != section else { return }
                        withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                            selection = section
                        }
                    } label: {
                        navButtonLabel(section: section, isSelected: isSelected, isHovered: isHovered)
                    }
                    .buttonStyle(SidebarNavButtonStyle())
                    .anchorPreference(key: SidebarItemBoundsKey.self, value: .bounds) { [section: $0] }
                    .onHover { hoveredSection = $0 ? section : (hoveredSection == section ? nil : hoveredSection) }
                    .accessibilityAddTraits(isSelected ? .isSelected : [])
                }
            }
            .backgroundPreferenceValue(SidebarItemBoundsKey.self) { anchors in
                GeometryReader { proxy in
                    ZStack(alignment: .topLeading) {
                        // 悬停轻提示囊：指针在未选中按钮间移动时平滑跟随
                        if let hovered = hoveredSection, hovered != selection, let anchor = anchors[hovered] {
                            let rect = proxy[anchor]
                            navShape
                                .fill(Color.primary.opacity(scheme == .dark ? 0.075 : 0.048))
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                                .transition(.opacity)
                        }

                        // 唯一常驻的选中态 Liquid Glass 滑块：永不卸载重建，点击任意按钮均以可打断弹簧沿侧栏顺滑滑移
                        if let anchor = anchors[selection] {
                            let rect = proxy[anchor]
                            activeNavPill
                                .frame(width: rect.width, height: rect.height)
                                .offset(x: rect.minX, y: rect.minY)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .animation(reduceMotion ? nil : ProductMotion.pillGlide, value: selection)
                    .animation(reduceMotion ? nil : ProductMotion.hover, value: hoveredSection)
                }
            }

            Spacer(minLength: 16)
            Divider().opacity(0.45).padding(.bottom, 10)
            status
        }
        .padding(.top, 38)
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(width: BBDesign.sidebarWidth)
        .frame(maxHeight: .infinity)
        .background {
            sidebarRailBackground
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(scheme == .dark ? Color.white.opacity(0.08) : Color.black.opacity(0.07))
                .frame(width: 0.5)
                .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private var activeNavPill: some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            Color.clear
                .glassEffect(
                    .regular.tint(Color.bbBlue.opacity(scheme == .dark ? 0.24 : 0.12)).interactive(),
                    in: navShape
                )
        } else {
            navShape
                .fill(Color.bbBlue.opacity(scheme == .dark ? 0.22 : 0.12))
        }
    }

    private func navButtonLabel(section: ProductSection, isSelected: Bool, isHovered: Bool) -> some View {
        // 前景视图恒定单一结构（无 if/else 重建），确保图标 symbolEffect 与前景色平滑过渡。
        HStack(spacing: 10) {
            Image(systemName: isSelected ? section.selectedSystemImage : section.systemImage)
                .font(.system(size: 13.5, weight: isSelected ? .semibold : .regular))
                .frame(width: 20)
                .scaleEffect(isSelected && !reduceMotion ? 1.05 : 1.0)
                .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace.downUp.byLayer))
                .accessibilityHidden(true)
            Text(section.title)
                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8.5)
        .foregroundStyle(
            isSelected
                ? Color.bbBlue
                : Color.bbInk.opacity(isHovered ? 0.96 : 0.78)
        )
        .contentShape(navShape)
        .animation(reduceMotion ? nil : ProductMotion.selection, value: isSelected)
        .animation(reduceMotion ? nil : ProductMotion.hover, value: isHovered)
    }

    private var sidebarRailBackground: some View {
        // 干净的全高原生中性侧栏底面（无整块浮空玻璃），仅承载标题、玻璃导航按钮与底部状态。
        (scheme == .dark
            ? Color(red: 0.086, green: 0.090, blue: 0.102)
            : Color(red: 0.935, green: 0.940, blue: 0.950))
            .ignoresSafeArea()
    }
}

/// 实时供电状态收进侧栏底部独立叶视图，防止导航树跟随采样 tick 重建。
private struct SidebarBatteryStatus: View {
    @Environment(PowerSampler.self) private var sampler
    @Environment(ProductNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        let presentation = sampler.statePresentation
        let known = sampler.currentSourceKnown
        let level: Double? = known ? sampler.currentLevel : nil
        let displayPercent = level.map { BatteryLevelPresentation.percent($0) }
        let target = sampler.chargePolicySnapshot.expiring(
            at: Date(), ttl: ChargePolicyMonitor.cacheTTL
        ).targetPercent

        Button {
            withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                navigation.go(.overview)
            }
        } label: {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Image(systemName: presentation.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(presentation.tint)
                    Text(displayPercent.map { "\($0)%" } ?? "—")
                        .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(Color.bbInk)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : ProductMotion.reading, value: displayPercent)
                    Spacer(minLength: 4)
                    Circle()
                        .fill(presentation.tint)
                        .frame(width: 6, height: 6)
                        .animation(reduceMotion ? nil : ProductMotion.reading, value: presentation.mode)
                }
                BatteryChargeGauge(level: level, mode: presentation.mode, targetPercent: target, height: 5)
                Text(presentation.mode == .charging ? "正在充电" : presentation.title)
                    .font(BBType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(
                hovered ? Color.primary.opacity(0.05) : Color.clear,
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
            .animation(reduceMotion ? nil : ProductMotion.hover, value: hovered)
        }
        .buttonStyle(ProductPressStyle())
        .onHover { hovered = $0 }
        .accessibilityElement(children: .combine)
        .accessibilityHint("点击返回概览")
    }
}
