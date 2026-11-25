import SwiftUI

struct OverviewView: View {
    @Environment(UsageReportModel.self) private var reports
    @Environment(ProductNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let todayLabel = ProductDateFormatting.string(
            from: reports.today?.date ?? Date(),
            format: "M月d日 EEEE",
            timeZone: reports.calendar.timeZone,
            localeIdentifier: "zh_CN"
        )
        VStack(spacing: 0) {
            ProductPageHeader(title: "概览", subtitle: "此刻的状态，今天的记录")
            ScrollView {
                VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                    CurrentPowerCard()

                    HStack(alignment: .firstTextBaseline) {
                        Text("今日记录")
                            .font(BBType.sectionTitle)
                            .foregroundStyle(Color.bbInk)
                        Spacer()
                        StatusPillBadge(
                            text: todayLabel,
                            systemImage: "calendar",
                            tint: .bbBlue
                        )
                    }
                    .padding(.top, 4)

                    HStack(alignment: .top, spacing: BBDesign.sectionSpacing) {
                        TodayPowerCard(calendar: reports.calendar)
                        todayBatteryCard
                    }
                    .fixedSize(horizontal: false, vertical: true)

                    OverviewHealthRow()

                    if let error = reports.error {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                            Text(error).font(BBType.body)
                        }
                        .foregroundStyle(.orange)
                        .productWell(tint: .orange)
                    }
                }
                .padding(.horizontal, BBDesign.pagePadding)
                .padding(.bottom, 28)
                .frame(maxWidth: BBDesign.contentMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .productScrollEdges()
        }
    }

    private var todayBatteryCard: some View {
        let today = reports.today
        let hasEvidence = today?.hasEvidence == true
        let screenOn = today?.screenOnSeconds ?? 0
        let screenOff = today?.screenOffSeconds ?? 0
        let totalBattery = today?.batterySeconds ?? 0
        let durationText = hasEvidence ? UsageTimeFormat.duration(totalBattery) : "—"

        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "电池使用", systemImage: "battery.75percent", tint: .bbMint) {
                CardActionChip(title: "详情", tint: .bbBlue) {
                    withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                        navigation.go(.battery)
                    }
                }
            }

            Text(durationText)
                .font(BBType.metricLarge.monospacedDigit())
                .foregroundStyle(Color.bbInk)

            VStack(alignment: .leading, spacing: 7) {
                if hasEvidence && totalBattery > 0 {
                    let onRatio = min(1, max(0, screenOn / totalBattery))
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            if screenOn > 0 {
                                Capsule()
                                    .fill(Color.bbMint)
                                    .frame(width: max(6, geo.size.width * onRatio))
                            }
                            if screenOff > 0 {
                                Capsule()
                                    .fill(Color.bbSlateBlue.opacity(0.65))
                            }
                        }
                    }
                    .frame(height: 6)

                    HStack(spacing: 12) {
                        legendDot(color: .bbMint, text: "亮屏 \(UsageTimeFormat.duration(screenOn))")
                        legendDot(color: .bbSlateBlue, text: "息屏 \(UsageTimeFormat.duration(screenOff))")
                    }
                } else if hasEvidence {
                    StatusPillBadge(text: "今日全程接电", tint: .bbBlue)
                } else {
                    StatusPillBadge(text: "等待使用记录", tint: .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .productCard(accent: .bbMint)
    }

    private func legendDot(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(text)
                .font(BBType.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct TodayPowerSummary: Equatable, Sendable {
    var averageWatts: Double?
    var peakWatts: Double?
    var effectiveSeconds: TimeInterval = 0
}

private struct TodayPowerCard: View {
    var calendar: Calendar = .current
    @Environment(ProductNavigation.self) private var navigation
    @Environment(\.isSectionActive) private var isSectionActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var summary = TodayPowerSummary()
    @State private var needsReload = false
    @State private var computeGeneration: UInt64 = 0

    var body: some View {
        let averageText = summary.averageWatts.map { String(format: "%.1f", $0) } ?? "—"
        let hasData = summary.averageWatts != nil

        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "今日功耗", systemImage: "waveform.path.ecg", tint: .bbAmber) {
                CardActionChip(title: "详情", tint: .bbBlue) {
                    withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                        navigation.go(.energy)
                    }
                }
            }

            HStack(alignment: .firstTextBaseline, spacing: 5) {
                Text(averageText)
                    .font(BBType.metricLarge.monospacedDigit())
                    .foregroundStyle(Color.bbInk)
                if hasData {
                    Text("W")
                        .font(BBType.bodyMedium)
                        .foregroundStyle(.secondary)
                    Text("今日平均")
                        .font(BBType.caption)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 2)
                }
            }

            HStack(spacing: 8) {
                if hasData {
                    if let peak = summary.peakWatts {
                        StatusPillBadge(
                            text: String(format: "峰值 %.1f W", peak),
                            tint: .bbAmber
                        )
                    }
                    if summary.effectiveSeconds > 0 {
                        StatusPillBadge(
                            text: "已记录 \(UsageTimeFormat.duration(summary.effectiveSeconds))",
                            tint: .bbBlue
                        )
                    }
                } else {
                    StatusPillBadge(text: "正在记录今日功耗", tint: .secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .productCard(accent: .bbAmber)
        .task {
            await reloadAsync()
        }
        .onReceive(NotificationCenter.default.publisher(for: .batterySnapshotsDidChange)) { _ in
            if isSectionActive {
                Task { await reloadAsync() }
            } else {
                needsReload = true
            }
        }
        .onChange(of: isSectionActive) { _, active in
            if active && needsReload {
                Task { await reloadAsync() }
            }
        }
        .onChange(of: calendar.timeZone.identifier) { _, _ in
            Task { await reloadAsync() }
        }
    }

    @MainActor
    private func reloadAsync() async {
        needsReload = false
        computeGeneration &+= 1
        let gen = computeGeneration
        let cal = calendar
        let computed = await Task.detached(priority: .utility) {
            let snapshots = DataStore.shared.localSnapshots()
            return Self.computeTodaySummary(from: snapshots, calendar: cal, now: Date())
        }.value
        guard !Task.isCancelled, gen == computeGeneration else { return }
        summary = computed
    }

    nonisolated private static func computeTodaySummary(
        from source: [BatterySnapshot],
        calendar: Calendar,
        now: Date
    ) -> TodayPowerSummary {
        let dayStart = calendar.startOfDay(for: now)
        guard now > dayStart else { return TodayPowerSummary() }

        if let summary = RangeStatistics.systemPowerSummary(
            snapshots: source,
            rangeStart: dayStart,
            rangeEnd: now
        ) {
            return TodayPowerSummary(
                averageWatts: summary.averageWatts,
                peakWatts: summary.peakWatts,
                effectiveSeconds: summary.effectiveSeconds
            )
        }

        let hasAnyAggregateToday = source.contains {
            guard let windowStart = $0.aggregateWindowStart else { return false }
            return windowStart >= dayStart && windowStart < now
        }
        guard !hasAnyAggregateToday else { return TodayPowerSummary() }

        // 无分钟聚合时的旧快照回退（仅统计可信系统负载）
        let legacy = source.filter {
            $0.timestamp >= dayStart && $0.timestamp <= now && ($0.trustedSystemLoad ?? 0) > 0.05
        }
        guard !legacy.isEmpty else { return TodayPowerSummary() }
        let sum = legacy.reduce(0.0) { $0 + $1.wattage }
        let peak = legacy.map(\.wattage).max() ?? 0
        return TodayPowerSummary(
            averageWatts: sum / Double(legacy.count),
            peakWatts: peak,
            effectiveSeconds: Double(legacy.count * 60)
        )
    }
}

struct CurrentPowerCard: View {
    @Environment(PowerSampler.self) private var sampler
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let presentation = sampler.statePresentation
        let level: Double? = sampler.currentSourceKnown ? sampler.currentLevel : nil
        let target = sampler.chargePolicySnapshot.expiring(
            at: Date(), ttl: ChargePolicyMonitor.cacheTTL
        ).targetPercent

        VStack(alignment: .leading, spacing: 16) {
            PowerStatusHeading(presentation: presentation, level: level)

            VStack(alignment: .leading, spacing: 8) {
                BatteryChargeGauge(
                    level: level,
                    mode: presentation.mode,
                    targetPercent: target,
                    height: 10
                )
                HStack(spacing: 8) {
                    RuntimeSummary()
                    Spacer(minLength: 8)
                    if let target {
                        Text("充电上限 \(target)%")
                            .font(BBType.captionMedium.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            CurrentPowerReadouts()
        }
        .padding(BBDesign.heroPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .productSurface(.hero, tint: presentation.tint, cornerRadius: BBDesign.heroRadius)
        .animation(reduceMotion ? nil : ProductMotion.reading, value: presentation.mode)
    }
}

struct PowerStatusHeading: View {
    let presentation: PowerStatePresentation
    let level: Double?
    var compact = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            HStack(alignment: .top, spacing: 11) {
                if reduceMotion {
                    BrandSymbol(systemImage: presentation.symbol, tint: presentation.tint, size: compact ? 30 : 38)
                } else {
                    BrandSymbol(systemImage: presentation.symbol, tint: presentation.tint, size: compact ? 30 : 38)
                        .symbolEffect(.bounce, options: .nonRepeating, value: presentation.symbol)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(presentation.title)
                        .font(.system(size: compact ? 13.5 : 16, weight: .bold))
                        .foregroundStyle(Color.bbInk)
                    Text(presentation.detail)
                        .font(BBType.body)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(level.map { "\(BatteryLevelPresentation.percent($0))" } ?? "—")
                    .font(BBType.heroNumber(compact: compact).monospacedDigit())
                    .foregroundStyle(Color.bbInk)
                    .contentTransition(.numericText())
                    .animation(
                        reduceMotion ? nil : ProductMotion.reading,
                        value: level.map { BatteryLevelPresentation.percent($0) }
                    )
                if level != nil {
                    Text("%")
                        .font(.system(size: compact ? 14 : 17, weight: .semibold, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .fixedSize()
        }
    }
}

extension PowerStatePresentation {
    var tint: Color {
        switch mode {
        case .battery: .bbMint
        case .charging: .bbAmber
        case .external: .bbBlue
        case .unknown: .secondary
        }
    }
}

struct RuntimeSummary: View {
    @Environment(PowerSampler.self) private var sampler
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if sampler.statePresentation.mode == .battery {
                if let estimate = sampler.dischargeEstimate ?? sampler.systemReportedEstimate {
                    let duration = UsageTimeFormat.duration(estimate.valueHours * 3_600)
                    let label = estimate.basis == .systemReported
                        ? "预计可用 \(duration) · 系统估算"
                        : "预计可用 \(duration)"
                    StatusPillBadge(
                        text: label,
                        systemImage: "clock",
                        tint: .bbMint
                    )
                } else {
                    StatusPillBadge(text: "续航估算中", systemImage: "clock", tint: .secondary)
                }
            } else if sampler.statePresentation.mode == .charging {
                let effectivePolicy = sampler.chargePolicySnapshot.expiring(
                    at: Date(), ttl: ChargePolicyMonitor.cacheTTL
                )
                let chargingGoal = effectivePolicy.chargingEstimateTargetPercent
                if let estimate = sampler.preferredChargeEstimate,
                   let goal = estimate.goalPercent {
                    let duration = UsageTimeFormat.duration(estimate.valueHours * 3_600)
                    let targetText = Int(goal) >= 100 ? "充满" : "达 \(Int(goal))%"
                    let suffix = estimate.basis == .systemReported ? " · 系统估算" : ""
                    StatusPillBadge(
                        text: "预计 \(duration) 后\(targetText)\(suffix)",
                        systemImage: "bolt.badge.clock",
                        tint: .bbAmber
                    )
                } else {
                    let pendingText: String = if let chargingGoal, chargingGoal < 100 {
                        "达 \(chargingGoal)% 时间估算中"
                    } else {
                        "充满时间估算中"
                    }
                    StatusPillBadge(
                        text: pendingText,
                        systemImage: "bolt.badge.clock",
                        tint: .secondary
                    )
                }
            }
        }
        .animation(reduceMotion ? nil : ProductMotion.reveal, value: sampler.statePresentation.mode)
    }
}

struct CurrentPowerReadouts: View {
    @Environment(PowerSampler.self) private var sampler

    var body: some View {
        HStack(alignment: .top, spacing: 10) { metrics }
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var metrics: some View {
        if sampler.currentSourceKnown && sampler.currentExternalConnected {
            StatTile(
                icon: "bolt.fill",
                tint: .bbAmber,
                value: watts(sampler.currentAdapterInputPower, sampler.currentAdapterInputAvailable),
                unit: "W",
                label: "电源输入"
            )
        }
        StatTile(
            icon: "waveform.path.ecg",
            tint: .bbBlue,
            value: watts(sampler.currentWattage, sampler.currentPowerAvailable),
            unit: "W",
            label: "整机功耗"
        )
        if sampler.currentSourceKnown && sampler.currentExternalConnected && !sampler.currentIsCharging {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    BrandSymbol(systemImage: "pause.circle.fill", tint: .bbTeal, size: 20)
                    Text("电池状态")
                        .font(BBType.captionMedium)
                        .foregroundStyle(.secondary)
                }
                StatusPillBadge(
                    text: concisePluggedNotChargingLabel,
                    tint: .bbTeal
                )
            }
            .productWell(tint: .bbTeal, padding: 11)
        } else {
            StatTile(
                icon: sampler.currentIsCharging ? "battery.100percent.bolt" : "battery.75percent",
                tint: sampler.currentIsCharging ? .bbAmber : .bbMint,
                value: watts(sampler.currentBatteryPower, sampler.currentBatteryPowerAvailable),
                unit: "W",
                label: sampler.currentIsCharging ? "电池充入" : "电池放出"
            )
        }
    }

    private var concisePluggedNotChargingLabel: String {
        if let behavior = sampler.currentChargingBehaviorObservation,
           behavior.reason == .thermalProtection || behavior.state == .otherConfirmedPause
        {
            return sampler.pluggedNotChargingLabel
        }
        let target = sampler.chargePolicySnapshot.expiring(
            at: Date(), ttl: ChargePolicyMonitor.cacheTTL
        ).targetPercent
        if let target, sampler.currentLevel.isFinite, sampler.currentLevel >= Double(target) {
            return target == 100 ? "已充满 · 停充" : "已达上限 · 停充"
        }
        return sampler.pluggedNotChargingLabel
    }

    private func watts(_ value: Double, _ available: Bool) -> String {
        available && sampler.currentSourceKnown ? String(format: "%.1f", value) : "—"
    }
}

private struct OverviewHealthRow: View {
    @Environment(PowerSampler.self) private var sampler
    @Environment(ProductNavigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let health = sampler.healthMetric
        let temp = sampler.currentTemperature
        let cycles = sampler.currentInfo?.cycleCount
        let policy = sampler.chargePolicySnapshot.expiring(
            at: Date(), ttl: ChargePolicyMonitor.cacheTTL
        )

        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "电池状况", systemImage: "battery.100percent", tint: .bbMint) {
                CardActionChip(title: "健康详情", tint: .bbBlue) {
                    withAnimation(reduceMotion ? nil : ProductMotion.pillGlide) {
                        navigation.go(.health)
                    }
                }
            }

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 4),
                spacing: 10
            ) {
                StatTile(
                    icon: "heart.fill",
                    tint: .bbMint,
                    value: health.percent > 0 ? "\(Int(health.percent.rounded()))" : "—",
                    unit: health.percent > 0 ? "%" : "",
                    label: health.percent > 0 ? (health.sourceIsSystem ? "最大容量" : "容量比估算") : "最大容量"
                )
                StatTile(
                    icon: "arrow.2.circlepath",
                    tint: .bbBlue,
                    value: cycles.map { "\($0)" } ?? "—",
                    unit: cycles == nil ? "" : "次",
                    label: "循环次数"
                )
                StatTile(
                    icon: "thermometer.medium",
                    tint: .bbAmber,
                    value: temp.map { String(format: "%.1f", $0) } ?? "—",
                    unit: temp == nil ? "" : "°C",
                    label: "电池温度"
                )
                if let target = policy.targetPercent {
                    StatTile(
                        icon: "shield.lefthalf.filled",
                        tint: .bbTeal,
                        value: "\(target)",
                        unit: "%",
                        label: "充电上限"
                    )
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 6) {
                            BrandSymbol(systemImage: "shield.lefthalf.filled", tint: .bbTeal, size: 20)
                            Text("充电上限")
                                .font(BBType.captionMedium)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        ZStack(alignment: .leading) {
                            Text("0")
                                .font(BBType.metricSmall)
                                .hidden()
                            Text(policy.statusLabel)
                                .font(.system(size: 15.5, weight: .semibold, design: .rounded))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.78)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .productWell(tint: .bbTeal, padding: 11)
                    .accessibilityElement(children: .combine)
                }
            }
        }
        .productCard(accent: .bbMint)
    }
}

struct BatteryHealthPanel: View {
    @Environment(PowerSampler.self) private var sampler
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let health = sampler.healthMetric
        let info = sampler.currentInfo
        let temp = sampler.currentTemperature

        ScrollView {
            VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                HStack(spacing: 20) {
                    healthHeroSummary(health: health)
                    Spacer(minLength: 12)
                    HStack(spacing: 10) {
                        StatTile(
                            icon: "arrow.2.circlepath",
                            tint: .bbBlue,
                            value: info.map { "\($0.cycleCount)" } ?? "—",
                            unit: "次",
                            label: "循环次数"
                        )
                        .frame(width: 148)
                        StatTile(
                            icon: "thermometer.medium",
                            tint: .bbAmber,
                            value: temp.map { String(format: "%.1f", $0) } ?? "—",
                            unit: "°C",
                            label: "电池温度"
                        )
                        .frame(width: 148)
                    }
                }
                .padding(BBDesign.heroPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .productSurface(.hero, tint: .bbMint, cornerRadius: BBDesign.heroRadius)

                BatteryHealthTrendCard(records: sampler.healthHistory)

                VStack(alignment: .leading, spacing: 14) {
                    SectionHeader(title: "容量与电源", systemImage: "battery.100percent", tint: .bbMint) {
                        Button("打开系统电池设置") { sampler.openBatterySettings() }
                            .adaptiveGlassButton()
                            .controlSize(.small)
                    }

                    CapacityComparisonBar(
                        maxCapacity: info?.maxCapacity ?? 0,
                        designCapacity: info?.designCapacity ?? 0
                    )

                    LazyVGrid(
                        columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)],
                        spacing: 10
                    ) {
                        MetricWellCell(
                            title: "当前满充容量",
                            value: info.flatMap { $0.maxCapacity > 0 ? "\($0.maxCapacity) mAh" : nil } ?? "不可用",
                            systemImage: "battery.100percent",
                            tint: .bbMint
                        )
                        MetricWellCell(
                            title: "设计容量",
                            value: info.flatMap { $0.designCapacity > 0 ? "\($0.designCapacity) mAh" : nil } ?? "不可用",
                            systemImage: "ruler",
                            tint: .bbBlue
                        )
                        if let info, info.nominalCapacity > 0 && info.nominalCapacity != info.maxCapacity {
                            MetricWellCell(
                                title: "电池标称容量",
                                value: "\(info.nominalCapacity) mAh",
                                systemImage: "gauge.with.dots.needle.67percent",
                                tint: .bbTeal
                            )
                        }
                        if let info, info.designCycleCount > 0 {
                            MetricWellCell(
                                title: "设计循环上限",
                                value: "\(info.designCycleCount) 次",
                                systemImage: "arrow.2.circlepath",
                                tint: .bbBlue
                            )
                        }
                        MetricWellCell(
                            title: "适配器额定功率",
                            value: (sampler.currentSourceKnown && !sampler.currentExternalConnected)
                                ? "未接电源"
                                : (info.flatMap {
                                    $0.adapterWatts > 0 ? String(format: "%.0f W", $0.adapterWatts) : nil
                                } ?? "不可用"),
                            systemImage: "powerplug.fill",
                            tint: .bbAmber
                        )
                        MetricWellCell(
                            title: "系统充电上限",
                            value: sampler.chargePolicySnapshot.expiring(
                                at: Date(), ttl: ChargePolicyMonitor.cacheTTL
                            ).statusLabel,
                            systemImage: "shield.lefthalf.filled",
                            tint: .bbTeal
                        )
                        if let info, !info.adapterProtocol.isEmpty {
                            MetricWellCell(
                                title: "充电协议",
                                value: info.adapterProtocol,
                                systemImage: "cable.connector",
                                tint: .bbBlue
                            )
                        }
                    }

                    Text("充电上限和优化充电由 macOS 管理，BatteryArchive 读取并记录当前状态。")
                        .font(BBType.caption)
                        .foregroundStyle(.secondary)
                }
                .productCard(accent: .bbMint)

                if !health.sourceIsSystem {
                    Text("当前使用容量比估算；系统最大容量可用后会优先显示系统值。")
                        .font(BBType.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 4)
                }
            }
            .padding(.horizontal, BBDesign.pagePadding)
            .padding(.bottom, 28)
            .frame(maxWidth: BBDesign.contentMaxWidth, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .productScrollEdges()
    }

    private func healthHeroSummary(health: BatteryHealthMetric) -> some View {
        HealthRingHeroSummary(health: health)
    }
}

private struct HealthRingHeroSummary: View {
    let health: BatteryHealthMetric
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isSectionActive) private var isSectionActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealed = false

    var body: some View {
        let ratio = health.percent > 0 ? min(1, max(0, health.percent / 100)) : 0
        let drawnRatio = (revealed || reduceMotion) ? ratio : 0
        HStack(spacing: 16) {
            ZStack {
                Circle()
                    .stroke(Color.bbMint.opacity(scheme == .dark ? 0.18 : 0.14), lineWidth: 7)
                Circle()
                    .trim(from: 0, to: drawnRatio)
                    .stroke(
                        Color.bbMint,
                        style: StrokeStyle(lineWidth: 7, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(reduceMotion ? nil : ProductMotion.orbit, value: drawnRatio)
                Image(systemName: "heart.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Color.bbMint)
            }
            .frame(width: 56, height: 56)

            VStack(alignment: .leading, spacing: 5) {
                StatusPillBadge(
                    text: health.percent > 0 ? (health.sourceIsSystem ? "最大容量" : "容量比估算") : "健康度暂不可用",
                    tint: health.percent > 0 ? .bbMint : .secondary
                )
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(health.percent > 0 ? String(format: "%.0f", health.percent) : "—")
                        .font(BBType.heroNumber().monospacedDigit())
                        .foregroundStyle(Color.bbInk)
                        .contentTransition(.numericText())
                        .animation(reduceMotion ? nil : ProductMotion.reading, value: Int(health.percent.rounded()))
                    if health.percent > 0 {
                        Text("%")
                            .font(.system(size: 17, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onChange(of: isSectionActive, initial: true) { _, active in
            guard active, !revealed else { return }
            withAnimation(reduceMotion ? nil : ProductMotion.orbit) {
                revealed = true
            }
        }
    }
}
