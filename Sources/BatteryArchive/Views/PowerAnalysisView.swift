import SwiftUI
import Charts

private struct PowerRangeStats: Sendable {
    var average: Double = 0
    var peak: Double = 0
    var low: Double? = nil
    var sampleCount: Int = 0
    var coverage: TimeInterval = 0
}

private struct PowerRangeComputed: Sendable {
    var loadPoints: [TrendPoint]
    var temperaturePoints: [TrendPoint]
    var rangeTemperaturePeak: Double?
    var legacyLoadSnapshots: [BatterySnapshot]
    var rangeStats: PowerRangeStats
    var rangeOverallCoverage: Double
}

/// 功耗页信息架构：整机功耗 → 分项功耗 → 功耗趋势 / 温度趋势 → 电源诊断 → 高级采样。
///
/// 失效边界：页面根视图只持有历史状态（快照、时间范围等低频字段），
/// 每秒变化的整机功耗/电池功率/温度/组件读数全部收进独立叶视图，历史 Chart 经
/// EquatableView 与输入绑定，不被实时值带着重建。
struct PowerAnalysisView: View {
    @Environment(PowerSampler.self) private var sampler
    @Environment(\.isSectionActive) private var isSectionActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var snapshots: [BatterySnapshot] = []
    @State private var loadPoints: [TrendPoint] = []
    @State private var temperaturePoints: [TrendPoint] = []
    @State private var rangeTemperaturePeak: Double?
    @State private var legacyLoadSnapshots: [BatterySnapshot] = []
    @State private var rangeStats = PowerRangeStats()
    @State private var rangeOverallCoverage: Double = 0
    @State private var timeRange: TimeRange = .hour1
    @State private var needsSnapshotReload = true
    @State private var computeGeneration: UInt64 = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProductPageHeader(
                title: "功耗",
                subtitle: "整机功耗、分项估算与趋势",
                systemImage: "bolt.fill",
                tint: .bbAmber
            )

            ScrollView {
                LazyVStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                    PowerLoadHero(sampler: sampler)
                    ComponentBreakdownCard(sampler: sampler)
                    historyCard
                    temperatureCard
                    PowerDiagnosticsSection(sampler: sampler)
                    AdvancedSamplingCard(sampler: sampler)
                    dataSourceFootnote
                }
                .padding(.horizontal, BBDesign.pagePadding)
                .padding(.bottom, 28)
                .frame(maxWidth: BBDesign.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .productScrollEdges()
            .task {
                await reloadSnapshotsAsync()
            }
            .onReceive(NotificationCenter.default.publisher(for: .batterySnapshotsDidChange)) { _ in
                if isSectionActive {
                    Task { await reloadSnapshotsAsync() }
                } else {
                    needsSnapshotReload = true
                }
            }
            .onChange(of: isSectionActive) { _, active in
                if active && needsSnapshotReload {
                    Task { await reloadSnapshotsAsync() }
                }
            }
            .onChange(of: timeRange) {
                let source = snapshots
                let range = timeRange
                computeGeneration &+= 1
                let gen = computeGeneration
                Task {
                    let computed = await Task.detached(priority: .userInitiated) {
                        Self.computeRangeData(from: source, timeRange: range)
                    }.value
                    guard gen == computeGeneration else { return }
                    applyComputed(computed, animated: true)
                }
            }
        }
    }

    @MainActor
    private func reloadSnapshotsAsync() async {
        needsSnapshotReload = false
        computeGeneration &+= 1
        let gen = computeGeneration
        let range = timeRange
        let (loaded, computed) = await Task.detached(priority: .userInitiated) {
            let loaded = DataStore.shared.localSnapshots()
            let computed = Self.computeRangeData(from: loaded, timeRange: range)
            return (loaded, computed)
        }.value
        guard !Task.isCancelled, gen == computeGeneration else { return }
        snapshots = loaded
        applyComputed(computed, animated: false)
    }

    @MainActor
    private func applyComputed(_ computed: PowerRangeComputed, animated: Bool) {
        let update = {
            loadPoints = computed.loadPoints
            temperaturePoints = computed.temperaturePoints
            rangeTemperaturePeak = computed.rangeTemperaturePeak
            legacyLoadSnapshots = computed.legacyLoadSnapshots
            rangeStats = computed.rangeStats
            rangeOverallCoverage = computed.rangeOverallCoverage
        }
        if animated, !reduceMotion {
            withAnimation(ProductMotion.reading) { update() }
        } else {
            update()
        }
    }

    // MARK: - 范围数据重建（纯计算，可在后台执行）

    nonisolated private static func computeRangeData(
        from source: [BatterySnapshot],
        timeRange: TimeRange
    ) -> PowerRangeComputed {
        let now = Date()
        let cutoff = now.addingTimeInterval(-timeRange.hours * 3600)
        // 与 RangeStatistics 同口径：按 aggregateWindowStart 限窗并去重；系统与温度分别按各自覆盖率优选，避免丢弃同分钟温度样本。
        var uniqueSystemByWindow: [Date: BatterySnapshot] = [:]
        var uniqueTempByWindow: [Date: BatterySnapshot] = [:]
        for snap in source {
            guard let windowStart = snap.aggregateWindowStart,
                  windowStart >= cutoff, windowStart < now else { continue }
            if let existing = uniqueSystemByWindow[windowStart] {
                let newCov = snap.systemCoverage ?? 0
                let oldCov = existing.systemCoverage ?? 0
                if newCov > oldCov || (newCov == oldCov && snap.timestamp > existing.timestamp) {
                    uniqueSystemByWindow[windowStart] = snap
                }
            } else {
                uniqueSystemByWindow[windowStart] = snap
            }
            if let existing = uniqueTempByWindow[windowStart] {
                let newCov = snap.temperatureCoverage ?? 0
                let oldCov = existing.temperatureCoverage ?? 0
                if newCov > oldCov || (newCov == oldCov && snap.timestamp > existing.timestamp) {
                    uniqueTempByWindow[windowStart] = snap
                }
            } else {
                uniqueTempByWindow[windowStart] = snap
            }
        }
        let inRange = uniqueSystemByWindow.values.sorted {
            ($0.aggregateWindowStart ?? $0.timestamp) < ($1.aggregateWindowStart ?? $1.timestamp)
        }
        let tempInRange = uniqueTempByWindow.values.sorted {
            ($0.aggregateWindowStart ?? $0.timestamp) < ($1.aggregateWindowStart ?? $1.timestamp)
        }

        let loadPoints = trendPoints(
            from: inRange,
            value: { $0.systemPowerAverage },
            coverageGate: { ($0.systemCoverage ?? 0) >= 0.8 },
            maximum: { _ in nil },
            coverage: { $0.systemCoverage }
        )
        let temperaturePoints = trendPoints(
            from: tempInRange,
            value: { $0.temperatureAverage },
            coverageGate: { ($0.temperatureCoverage ?? 0) >= 0.5 },
            maximum: { $0.temperatureMaximum },
            coverage: { $0.temperatureCoverage }
        )
        // 区间最高温度必须在抽稀之前基于全量有效窗口计算，防止 24h 抽稀丢弃短时高温峰值。
        let rangeTemperaturePeak = tempInRange.compactMap { snap -> Double? in
            if let maxT = snap.temperatureMaximum, maxT.isFinite { return maxT }
            if (snap.temperatureCoverage ?? 0) >= 0.5, let avgT = snap.temperatureAverage, avgT.isFinite { return avgT }
            return nil
        }.max()

        let rangeOverallCoverage = RangeStatistics.overallSystemCoverage(
            snapshots: source, rangeStart: cutoff, rangeEnd: now
        )

        let (legacySnapshots, legacyStats) = computeLegacyStats(from: source, cutoff: cutoff, now: now)
        let stats = computeAggregateStats(from: inRange) ?? legacyStats

        return PowerRangeComputed(
            loadPoints: loadPoints,
            temperaturePoints: temperaturePoints,
            rangeTemperaturePeak: rangeTemperaturePeak,
            legacyLoadSnapshots: legacySnapshots,
            rangeStats: stats,
            rangeOverallCoverage: rangeOverallCoverage
        )
    }

    nonisolated private static func trendPoints(
        from snaps: [BatterySnapshot],
        value: (BatterySnapshot) -> Double?,
        coverageGate: (BatterySnapshot) -> Bool,
        maximum: (BatterySnapshot) -> Double?,
        coverage: (BatterySnapshot) -> Double?
    ) -> [TrendPoint] {
        var points: [TrendPoint] = []
        var previousTime: Date?
        for snap in snaps {
            guard let v = value(snap), coverageGate(snap) else { continue }
            let time = snap.aggregateWindowStart ?? snap.timestamp
            let isGap = previousTime.map { time.timeIntervalSince($0) > 90 } ?? false
            points.append(TrendPoint(
                time: time,
                value: v,
                maximum: maximum(snap),
                coverage: coverage(snap),
                breakBefore: isGap
            ))
            previousTime = time
        }
        return ChartDownsampler.downsampleTrendPoints(points, maxPoints: 240)
    }

    nonisolated private static func computeAggregateStats(from inRange: [BatterySnapshot]) -> PowerRangeStats? {
        let usable = inRange.filter {
            guard let cov = $0.systemCoverage, cov.isFinite, cov >= 0.8,
                  let avg = $0.systemPowerAverage, avg.isFinite,
                  let wh = $0.systemEnergyWh, wh.isFinite, wh >= 0 else { return false }
            return true
        }
        guard !usable.isEmpty else { return nil }

        let totalEnergy = usable.reduce(0) { $0 + ($1.systemEnergyWh ?? 0) }
        let effectiveSeconds = usable.reduce(0.0) { $0 + min(1, max(0, $1.systemCoverage ?? 0)) * 60 }
        let effectiveHours = effectiveSeconds / 3600
        guard effectiveHours > 0 else { return nil }
        let average = totalEnergy / effectiveHours
        let peak = usable.compactMap(\.systemPowerPeak).filter(\.isFinite).max() ?? 0
        let low = usable.compactMap(\.systemPowerAverage).filter(\.isFinite).min()

        return PowerRangeStats(
            average: average,
            peak: max(peak, average),
            low: low,
            sampleCount: usable.count,
            coverage: effectiveSeconds
        )
    }

    private static func legacyPoints(_ snaps: [BatterySnapshot]) -> [TrendPoint] {
        var points: [TrendPoint] = []
        var previousTime: Date?
        for snap in snaps {
            let isGap = previousTime.map { snap.timestamp.timeIntervalSince($0) > 90 } ?? false
            points.append(TrendPoint(time: snap.timestamp, value: snap.wattage, breakBefore: isGap))
            previousTime = snap.timestamp
        }
        // 在原始连续序列上标记真实缺口后再抽稀，避免 6h/24h 抽稀后点距 >90s 把整条曲线拆碎。
        return ChartDownsampler.downsampleTrendPoints(points, maxPoints: 240)
    }

    nonisolated private static func computeLegacyStats(
        from source: [BatterySnapshot],
        cutoff: Date,
        now: Date
    ) -> ([BatterySnapshot], PowerRangeStats) {
        let hasAggregates = source.contains {
            guard let windowStart = $0.aggregateWindowStart else { return false }
            return windowStart >= cutoff && windowStart < now
        }
        if hasAggregates {
            return ([], PowerRangeStats())
        }
        let filtered = source
            .filter { $0.timestamp >= cutoff && $0.timestamp <= now }
            .filter { $0.trustedSystemLoad != nil }
            .sorted { $0.timestamp < $1.timestamp }

        var count = 0
        var sum = 0.0
        var peak = 0.0
        var low: Double?
        for snap in filtered where snap.wattage > 0.05 {
            count += 1
            sum += snap.wattage
            peak = max(peak, snap.wattage)
            low = low.map { min($0, snap.wattage) } ?? snap.wattage
        }
        let stats = PowerRangeStats(
            average: count > 0 ? sum / Double(count) : 0,
            peak: count > 0 ? peak : 0,
            low: low,
            sampleCount: filtered.count,
            coverage: max(0, (filtered.last?.timestamp.timeIntervalSince(filtered.first?.timestamp ?? now)) ?? 0)
        )
        return (filtered, stats)
    }

    private var hasRangeStats: Bool {
        rangeStats.sampleCount > 0
    }

    // MARK: - 历史趋势

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "功耗趋势", systemImage: "waveform.path.ecg", tint: .bbAmber) {
                ProductSegmentedControl(
                    title: "时间范围",
                    selection: $timeRange,
                    options: TimeRange.allCases.map { .init($0, $0.rawValue) },
                    tint: .bbBlue
                )
                .frame(width: 210)
            }

            HStack(spacing: 10) { rangeStatTiles }

            HStack(spacing: 12) {
                ChartLegendItem(
                    label: "整机功耗",
                    color: .bbAmber,
                    value: currentLoadText
                )
                Spacer()
                StatusPillBadge(text: coverageText, tint: .bbBlue)
            }

            if loadPoints.isEmpty && legacyLoadSnapshots.isEmpty {
                EmptyChartState(
                    title: "正在建立功耗趋势",
                    detail: "有可用功耗数据后这里会持续更新",
                    systemImage: "bolt.slash"
                )
            } else if !loadPoints.isEmpty {
                TrendChartPlot(points: loadPoints, timeRange: timeRange, unit: "W", tintColor: .bbAmber)
                    .equatable()
            } else {
                TrendChartPlot(
                    points: Self.legacyPoints(legacyLoadSnapshots),
                    timeRange: timeRange,
                    unit: "W",
                    tintColor: .bbAmber
                )
                .equatable()
            }
        }
        .productCard(accent: .bbAmber)
    }

    @ViewBuilder
    private var rangeStatTiles: some View {
        StatTile(
            icon: "chart.bar.fill",
            tint: .bbBlue,
            value: hasRangeStats ? String(format: "%.1f", rangeStats.average) : "—",
            unit: "W",
            label: "平均功耗"
        )
        StatTile(
            icon: "arrow.up.circle.fill",
            tint: .bbAmber,
            value: hasRangeStats ? String(format: "%.1f", rangeStats.peak) : "—",
            unit: "W",
            label: "峰值功耗"
        )
        StatTile(
            icon: "arrow.down.circle.fill",
            tint: .bbMint,
            value: hasRangeStats ? rangeStats.low.map { String(format: "%.1f", $0) } ?? "—" : "—",
            unit: "W",
            label: "最低功耗"
        )
    }

    private var currentLoadText: String? {
        if let last = loadPoints.last {
            return String(format: "%.1f W", last.value)
        }
        return legacyLoadSnapshots.last.map { String(format: "%.1f W", $0.wattage) }
    }

    /// 温度趋势：v5 时长加权平均，顶部摘要胶囊经叶视图隔离实时温度。
    private var temperatureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "电池温度趋势", systemImage: "thermometer.medium", tint: .orange) {
                TemperatureSummaryChips(
                    sampler: sampler,
                    peakTemperature: rangeTemperaturePeak,
                    timeRange: timeRange
                )
            }
            if temperaturePoints.isEmpty {
                EmptyChartState(
                    title: "正在建立温度趋势",
                    detail: "持续运行几分钟后会自动绘制电池温度曲线",
                    systemImage: "thermometer"
                )
            } else {
                TrendChartPlot(
                    points: temperaturePoints,
                    timeRange: timeRange,
                    unit: "°C",
                    tintColor: .orange,
                    isTemperature: true
                )
                .equatable()
            }
        }
        .productCard(accent: .orange)
    }

    private var coverageText: String {
        guard hasRangeStats, rangeStats.coverage > 0 else {
            return rangeStats.sampleCount == 1 ? "正在采集数据" : "尚无记录"
        }
        let duration = UsageTimeFormat.duration(rangeStats.coverage)
        if rangeOverallCoverage > 0 && rangeOverallCoverage < 0.9 {
            return "已记录 \(duration) · 部分时段未记录"
        }
        return "已记录 \(duration)"
    }

    private var dataSourceFootnote: some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle").font(.system(size: 11))
            Text("整机功耗优先读取系统功率数据，离电时结合电池放电计算；CPU / GPU / 内存分项为估算值。")
                .font(BBType.caption)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 4)
    }
}

// MARK: - 实时温度摘要胶囊（独立叶视图防止根视图随读数刷新）

private struct TemperatureSummaryChips: View {
    let sampler: PowerSampler
    let peakTemperature: Double?
    let timeRange: TimeRange

    var body: some View {
        HStack(spacing: 6) {
            if let current = sampler.currentTemperature {
                StatusPillBadge(text: String(format: "当前 %.1f°C", current), tint: .orange)
            }
            if let peak = peakTemperature {
                StatusPillBadge(text: "近\(timeRange.rawValue)最高 \(String(format: "%.1f°C", peak))", tint: .bbAmber)
            }
        }
    }
}

// MARK: - 当前功耗英雄卡（左右平衡双栏，每秒失效仅限此视图）

private struct PowerLoadHero: View {
    let sampler: PowerSampler
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let heroTint: Color = sampler.currentPowerAvailable
            ? (sampler.currentPowerIsEstimated ? .bbAmber : .bbBlue)
            : .bbBlue

        HStack(alignment: .center, spacing: 20) {
            leftSummary
            Spacer(minLength: 12)
            rightBalanceGrid
                .frame(maxWidth: 380)
        }
        .padding(BBDesign.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .productSurface(.hero, tint: heroTint, cornerRadius: BBDesign.heroRadius)
        .animation(reduceMotion ? nil : ProductMotion.reading, value: heroTint)
    }

    private var leftSummary: some View {
        let formattedLoad = String(format: "%.1f", sampler.currentWattage)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                BrandSymbol(systemImage: "waveform.path.ecg", tint: .bbBlue, size: 28)
                Text("整机功耗")
                    .font(BBType.cardTitle)
                    .foregroundStyle(Color.bbInk)
                if sampler.currentPowerAvailable {
                    StatusPillBadge(text: sourceText, tint: sourceTint, showDot: true)
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                if sampler.currentPowerAvailable {
                    Text(formattedLoad)
                        .font(BBType.heroNumber().monospacedDigit())
                        .foregroundStyle(Color.bbInk)
                    Text("W")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                } else {
                    Text("当前不可用")
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }

            Text(powerSourceLine)
                .font(BBType.bodyMedium.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private var rightBalanceGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
            spacing: 8
        ) {
            MetricWellCell(
                title: "电源输入",
                value: inputText,
                systemImage: "bolt.fill",
                tint: .bbAmber
            )
            MetricWellCell(
                title: "电池功率",
                value: compactBatteryValue,
                systemImage: sampler.currentIsCharging ? "battery.100percent.bolt" : "battery.75percent",
                tint: sampler.currentIsCharging ? .bbAmber : .bbMint
            )
            MetricWellCell(
                title: "低电量模式",
                value: sampler.currentLowPowerModeEnabled ? "已开启" : "关闭",
                systemImage: "leaf.fill",
                tint: sampler.currentLowPowerModeEnabled ? .bbAmber : .bbTeal
            )
            MetricWellCell(
                title: "系统热压力",
                value: sampler.currentThermalState,
                systemImage: "thermometer.medium",
                tint: sampler.currentThermalState == "正常" ? .bbMint : .orange
            )
        }
    }

    private var sourceText: String {
        sampler.currentPowerIsEstimated ? "估算" : "实测"
    }

    private var sourceTint: Color {
        sampler.currentPowerIsEstimated ? .bbAmber : .bbMint
    }

    private var inputText: String {
        guard sampler.currentSourceKnown else { return "—" }
        guard sampler.currentExternalConnected else { return "未接电源" }
        return sampler.currentAdapterInputAvailable
            ? String(format: "%.1f W", sampler.currentAdapterInputPower)
            : "—"
    }

    private var compactBatteryValue: String {
        guard sampler.currentSourceKnown else { return "—" }
        if sampler.currentExternalConnected && !sampler.currentIsCharging {
            return "未充电"
        }
        guard sampler.currentBatteryPowerAvailable else { return "—" }
        return String(format: "%@%.1f W", sampler.currentIsCharging ? "+" : "-", sampler.currentBatteryPower)
    }

    private var powerSourceLine: String {
        guard sampler.currentSourceKnown else { return "电源状态读取中" }
        if !sampler.currentExternalConnected {
            return "电池供电"
        }
        return sampler.currentIsCharging ? "外接电源充电中" : "外接电源直供"
    }
}

// MARK: - 组件构成

/// 分项读数。占比只在「整机功耗有效且组件样本新鲜（<30s）」时显示；
/// 否则只给绝对瓦数，不制造无意义的百分比。
private struct ComponentBreakdownCard: View {
    let sampler: PowerSampler
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let freshnessLimit: TimeInterval = 30

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "分项功耗", systemImage: "cpu.fill", tint: .bbBlue) {
                StatusPillBadge(
                    text: sampler.helperEnabled ? "已开启" : "未开启",
                    tint: sampler.helperEnabled ? .bbMint : .secondary,
                    showDot: sampler.helperEnabled
                )
            }

            if sampler.helperEnabled {
                let now = Date()
                let age = now.timeIntervalSince(sampler.lastComponentPowerAt)
                let sampleFresh = age >= -2 && age <= Self.freshnessLimit
                let isStale = age > Self.freshnessLimit

                VStack(spacing: 11) {
                    componentBar(label: "CPU", value: sampler.cpuPower, icon: "cpu", color: .bbBlue, measured: sampler.cpuPowerAvailable, sampleFresh: sampleFresh)
                    componentBar(label: "GPU", value: sampler.gpuPower, icon: "square.stack.3d.up", color: .bbIce, measured: sampler.gpuPowerAvailable, sampleFresh: sampleFresh)
                    if sampler.dramPowerAvailable {
                        componentBar(label: "内存", value: sampler.dramPower, icon: "memorychip", color: .bbTeal, measured: sampler.dramPowerAvailable, sampleFresh: sampleFresh)
                    }
                }
                .productWell(tint: .bbBlue, padding: 12)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))

                stalenessNote(isStale: isStale)

                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 10.5))
                    Text("分项功耗为估算值，之和不等于整机功耗（屏幕等其他部件计入整机）。")
                        .font(BBType.caption)
                }
                .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 12) {
                    BrandSymbol(systemImage: "lock.fill", tint: .bbBlue, size: 30)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开启高级采样后显示 CPU、GPU 与内存分项估算")
                            .font(BBType.bodyMedium)
                            .foregroundStyle(Color.bbInk)
                        Text("关闭时不影响基础功耗与电池记录，开启时按需安装后台采样服务。")
                            .font(BBType.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .productWell(tint: .bbBlue, padding: 12)
                .transition(reduceMotion ? .identity : .opacity)
            }
        }
        .productCard(accent: .bbBlue)
        .animation(reduceMotion ? nil : ProductMotion.reveal, value: sampler.helperEnabled)
    }

    @ViewBuilder
    private func stalenessNote(isStale: Bool) -> some View {
        if isStale {
            StatusPillBadge(
                text: sampler.componentPowerError ?? "正在等待分项数据更新…",
                systemImage: "clock.badge.exclamationmark",
                tint: .bbAmber
            )
        }
    }

    private func componentBar(
        label: String,
        value: Double,
        icon: String,
        color: Color,
        measured: Bool,
        sampleFresh: Bool
    ) -> some View {
        let total = sampler.currentWattage
        let percentVisible = measured && sampler.currentPowerAvailable && !sampler.currentPowerIsEstimated
            && sampleFresh
        let roundedPercent = percentVisible && total > 0 ? Int(min(100, value / total * 100).rounded()) : 0
        let fillFraction = Double(roundedPercent) / 100.0
        let readoutText = !sampleFresh
            ? "等待读数"
            : (!measured
                ? "—"
                : (percentVisible ? String(format: "%.1f W · %d%%", value, roundedPercent) : String(format: "%.1f W", value)))

        return HStack(spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 16)
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.bbInk)
            }
            .frame(width: 66, alignment: .leading)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(color.opacity(scheme == .dark ? 0.16 : 0.10))
                    Capsule()
                        .fill(LinearGradient(colors: [color, .bbHaloCyan], startPoint: .leading, endPoint: .trailing))
                        .frame(width: geo.size.width * fillFraction)
                }
            }
            .frame(height: 8)

            Text(readoutText)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(sampleFresh && measured ? Color.bbInk : .secondary)
                .frame(minWidth: 96, alignment: .trailing)
        }
    }
}

// MARK: - 电源诊断（默认折叠）

private struct PowerDiagnosticsSection: View {
    let sampler: PowerSampler

    var body: some View {
        ProductDisclosure {
            SectionHeader(title: "电源诊断", systemImage: "dial.min.fill", tint: .bbTeal)
        } content: {
            VStack(alignment: .leading, spacing: 12) {
                LazyVGrid(
                    columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                    spacing: 8
                ) {
                    MetricWellCell(title: "电池电压", value: sampler.currentVoltage > 0 ? String(format: "%.2f V", sampler.currentVoltage / 1_000) : "—", tint: .bbBlue)
                    MetricWellCell(
                        title: "瞬时电流",
                        value: (sampler.currentSourceKnown && sampler.currentVoltage > 0)
                            ? String(format: "%.0f mA", sampler.currentAmperage) : "—",
                        tint: .bbBlue
                    )
                    MetricWellCell(
                        title: "电池温度",
                        value: sampler.temperatureMetric.value.map { String(format: "%.1f°C", $0) } ?? "—",
                        tint: .bbAmber
                    )
                    MetricWellCell(title: "适配器输入功率", value: adapterInputText, tint: .bbAmber)
                    MetricWellCell(title: "适配器额定功率", value: adapterWattsText, tint: .bbTeal)
                    MetricWellCell(title: "充电协议", value: sampler.currentInfo?.adapterProtocol ?? "—", tint: .bbTeal)
                }

                Text("数据质量")
                    .font(BBType.captionMedium)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)

                VStack(spacing: 8) {
                    qualityRow("整机功耗", metric: sampler.loadMetric, valueText: loadQualityValue)
                    qualityRow("电源输入", metric: sampler.inputPowerMetric, valueText: adapterInputText)
                    qualityRow("电池功率", metric: sampler.batteryPowerMetric, valueText: batteryPowerQualityValue)
                    qualityRow("电池温度", metric: sampler.temperatureMetric, valueText: temperatureQualityValue)
                }
            }
            .padding(.top, 10)
            .padding(.horizontal, 4)
        }
        .productCard(padding: 14, accent: .bbTeal)
    }

    private var loadQualityValue: String {
        guard sampler.loadMetric.availability == .available, let v = sampler.loadMetric.value else { return "—" }
        return String(format: "%.1f W", v)
    }

    private var batteryPowerQualityValue: String {
        guard sampler.batteryPowerMetric.availability == .available, let v = sampler.batteryPowerMetric.value else { return "—" }
        return String(format: "%.1f W", v)
    }

    private var temperatureQualityValue: String {
        guard sampler.temperatureMetric.availability == .available, let v = sampler.temperatureMetric.value else { return "—" }
        return String(format: "%.1f°C", v)
    }

    private func qualityRow(_ label: String, metric: TelemetrySample<Double>, valueText: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(BBType.bodyMedium)
                    .foregroundStyle(Color.bbInk)
                Spacer()
                Text(valueText)
                    .font(.system(size: 12, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.bbInk)
            }
            HStack(spacing: 6) {
                if metric.source != .unavailable {
                    StatusPillBadge(text: metric.source.displayName, tint: .bbTeal)
                }
                if metric.availability == .available {
                    StatusPillBadge(
                        text: metric.isEstimated ? "估算" : "实测",
                        tint: metric.isEstimated ? .bbAmber : .bbMint
                    )
                } else {
                    StatusPillBadge(text: "不可用", tint: .secondary)
                }
                Spacer()
                Text(qualityTimingText(metric))
                    .font(BBType.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .productWell(tint: .bbTeal, padding: 10)
    }

    private func qualityTimingText(_ metric: TelemetrySample<Double>) -> String {
        guard metric.readAt != .distantPast else { return "" }
        let stableSeconds = Int(metric.stableFor(asOf: Date()))
        let stable = stableSeconds < 60 ? "\(stableSeconds)s" : "\(stableSeconds / 60)m"
        let readTime = metric.readAt.formatted(.dateTime.hour().minute().second())
        return "读取于 \(readTime) · \(stable) 未变"
    }

    private var adapterWattsText: String {
        guard let watts = sampler.currentInfo?.adapterWatts, watts > 0 else { return "—" }
        return String(format: "%.0f W", watts)
    }

    private var adapterInputText: String {
        let watts = sampler.currentAdapterInputPower
        guard sampler.currentAdapterInputAvailable else { return "—" }
        return String(format: "%.1f W", watts)
    }
}

// MARK: - 高级采样（底部）

struct AdvancedSamplingCard: View {
    let sampler: PowerSampler
    var showRemovalControl: Bool = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmRemoveHelper = false

    init(sampler: PowerSampler, showRemovalControl: Bool = false) {
        self.sampler = sampler
        self.showRemovalControl = showRemovalControl
    }

    var body: some View {
        let state = sampler.helperState
        let enabled = sampler.helperEnabled

        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                BrandSymbol(systemImage: stateIcon(state), tint: stateTint(state), size: 32)
                    .contentTransition(reduceMotion ? .identity : .symbolEffect(.replace))
                VStack(alignment: .leading, spacing: 2) {
                    Text("高级采样")
                        .font(BBType.cardTitle)
                        .foregroundStyle(Color.bbInk)
                    Text(stateSubtitle(state))
                        .font(BBType.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if sampler.isHelperBusy {
                    ProgressView().controlSize(.small)
                } else {
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { enabled },
                            set: { newValue in
                                Task { @MainActor in
                                    await sampler.setAdvancedSamplingEnabled(newValue)
                                }
                            }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
            }

            if case .needsUpdate = state {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text("后台服务需要更新；再次开启高级采样时会请求管理员授权。").font(BBType.caption)
                }
                .foregroundStyle(.orange)
                .productWell(tint: .orange, padding: 10)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }

            if case .error(let message) = state {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                    Text(message)
                        .font(BBType.caption)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("重试") {
                        Task { @MainActor in
                            await sampler.setAdvancedSamplingEnabled(true)
                        }
                    }
                    .adaptiveGlassButton(tint: .red)
                    .controlSize(.small)
                }
                .foregroundStyle(.red)
                .productWell(tint: .red, padding: 10)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }

            Text("开启后，查看「功耗」页时每 10 秒采样 CPU / GPU / 内存分项功耗（首次需管理员授权）；离开功耗页或关闭窗口后自动暂停，后台服务空闲后自动退出。")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showRemovalControl {
                Divider().opacity(0.4)

                HStack(spacing: 8) {
                    Text("辅助服务状态")
                        .font(BBType.captionMedium)
                        .foregroundStyle(.secondary)
                    Spacer()
                    StatusPillBadge(text: state.label, tint: helperStatusTint(state), showDot: true)
                }

                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("后台辅助服务")
                            .font(BBType.captionMedium)
                            .foregroundStyle(Color.bbInk)
                        Text("移除需管理员授权，再次开启高级采样时将重新安装")
                            .font(BBType.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 8)
                    Button {
                        confirmRemoveHelper = true
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: "trash")
                                .font(.system(size: 10.5, weight: .semibold))
                            Text("移除辅助服务…")
                        }
                    }
                    .adaptiveGlassButton(tint: sampler.isHelperInstalled ? .red : nil)
                    .controlSize(.small)
                    .disabled(sampler.isHelperBusy || !sampler.isHelperInstalled)
                }
                .productWell(tint: sampler.isHelperInstalled ? .red : .secondary, padding: 10)
            }
        }
        .productCard(accent: stateTint(state))
        .animation(reduceMotion ? nil : ProductMotion.reveal, value: state)
        .alert("移除辅助服务", isPresented: $confirmRemoveHelper) {
            Button("移除", role: .destructive) {
                Task { @MainActor in await sampler.removeHelperService() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("移除辅助服务需要一次管理员授权。移除后，再次开启高级采样时需要重新安装后台服务。")
        }
    }

    private func helperStatusTint(_ state: HelperLifecycleState) -> Color {
        switch state {
        case .enabled: .bbMint
        case .needsUpdate: .orange
        case .error: .red
        case .starting, .removing, .disabled: .secondary
        }
    }

    private func stateIcon(_ state: HelperLifecycleState) -> String {
        switch state {
        case .enabled: "shield.checkered"
        case .starting: "hourglass"
        case .removing: "trash"
        case .needsUpdate: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        case .disabled: "shield.slash"
        }
    }

    private func stateTint(_ state: HelperLifecycleState) -> Color {
        switch state {
        case .enabled: .bbMint
        case .needsUpdate: .orange
        case .error: .red
        case .starting, .removing, .disabled: .bbBlue
        }
    }

    private func stateSubtitle(_ state: HelperLifecycleState) -> String {
        switch state {
        case .disabled: "未开启 · 基础监控照常运行"
        case .starting: "正在准备后台服务…"
        case .removing: "正在移除后台服务…"
        case .enabled: "已开启 · 查看功耗页时按需采样"
        case .needsUpdate: "后台服务需要更新，开启时将自动升级"
        case .error: "上次启动未成功，可点击重试"
        }
    }
}
