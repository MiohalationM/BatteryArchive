import SwiftUI

struct StatusPopover: View {
    let sampler: PowerSampler
    var requestOpenMainWindow: ((ProductDestination) -> Void)?
    @Environment(UsageReportModel.self) private var reports
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let presentation = sampler.statePresentation
        let known = sampler.currentSourceKnown
        let level: Double? = known ? sampler.currentLevel : nil
        let effectivePolicy = sampler.chargePolicySnapshot.expiring(
            at: Date(), ttl: ChargePolicyMonitor.cacheTTL
        )
        let target = effectivePolicy.targetPercent
        let chargingGoal = effectivePolicy.chargingEstimateTargetPercent
        let badge = headerBadge(presentation: presentation, level: level)

        VStack(alignment: .leading, spacing: 12) {
            // 1. 顶栏（直接排版于 Popover 原生半透明表面，无大卡片嵌套）
            HStack(spacing: 7) {
                Image(nsImage: NSApplication.shared.applicationIconImage)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 17, height: 17)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                Text(AppBrand.displayName)
                    .font(.system(size: 12.5, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.bbInk)
                Spacer()
                StatusPillBadge(
                    text: badge.text,
                    systemImage: badge.icon,
                    tint: badge.tint,
                    showDot: badge.icon == nil
                )
            }

            // 2. 电量与供电状态焦点区（原生无卡片通透排版）
            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 10) {
                    if reduceMotion {
                        BrandSymbol(systemImage: presentation.symbol, tint: presentation.tint, size: 32)
                    } else {
                        BrandSymbol(systemImage: presentation.symbol, tint: presentation.tint, size: 32)
                            .symbolEffect(.bounce, options: .nonRepeating, value: presentation.symbol)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(presentation.title)
                            .font(.system(size: 14.5, weight: .bold))
                            .foregroundStyle(Color.bbInk)
                            .lineLimit(1)
                        Text(conciseDetail(presentation: presentation, target: target))
                            .font(BBType.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 6)
                    HStack(alignment: .firstTextBaseline, spacing: 2) {
                        Text(level.map { "\(BatteryLevelPresentation.percent($0))" } ?? "—")
                            .font(.system(size: 30, weight: .light, design: .rounded).monospacedDigit())
                            .foregroundStyle(Color.bbInk)
                            .contentTransition(.numericText())
                            .animation(
                                reduceMotion ? nil : ProductMotion.reading,
                                value: level.map { BatteryLevelPresentation.percent($0) }
                            )
                        if level != nil {
                            Text("%")
                                .font(.system(size: 13, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                }

                BatteryChargeGauge(
                    level: level,
                    mode: presentation.mode,
                    targetPercent: target,
                    height: 7
                )

                HStack(spacing: 6) {
                    popoverRuntimeText(mode: presentation.mode, chargingGoal: chargingGoal)
                    Spacer(minLength: 6)
                    if let target {
                        Text("上限 \(target)%")
                            .font(BBType.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            hairlineDivider

            // 3. 原生菜单列表式遥测行（去卡片化，左标右值对齐易扫读，悬停可直达对应详情页）
            VStack(spacing: 3) {
                PopoverTelemetryRow(
                    icon: "waveform.path.ecg",
                    tint: .bbBlue,
                    label: "整机功耗",
                    value: known && sampler.currentPowerAvailable
                        ? String(format: "%.1f", sampler.currentWattage) : "—",
                    unit: known && sampler.currentPowerAvailable ? "W" : "",
                    action: requestOpenMainWindow.map { open in { open(.energy) } }
                )
                if known && sampler.currentExternalConnected {
                    PopoverTelemetryRow(
                        icon: "bolt.fill",
                        tint: .bbAmber,
                        label: "电源输入",
                        value: sampler.currentAdapterInputAvailable
                            ? String(format: "%.1f", sampler.currentAdapterInputPower) : "—",
                        unit: sampler.currentAdapterInputAvailable ? "W" : "",
                        action: requestOpenMainWindow.map { open in { open(.energy) } }
                    )
                } else {
                    PopoverTelemetryRow(
                        icon: "battery.75percent",
                        tint: .bbMint,
                        label: known ? "电池放出" : "电池功率",
                        value: known && sampler.currentBatteryPowerAvailable
                            ? String(format: "%.1f", sampler.currentBatteryPower) : "—",
                        unit: known && sampler.currentBatteryPowerAvailable ? "W" : "",
                        action: requestOpenMainWindow.map { open in { open(.energy) } }
                    )
                }
                PopoverTelemetryRow(
                    icon: "thermometer.medium",
                    tint: .bbAmber,
                    label: "电池温度",
                    value: sampler.currentTemperature.map { String(format: "%.1f", $0) } ?? "—",
                    unit: sampler.currentTemperature == nil ? "" : "°C",
                    action: requestOpenMainWindow.map { open in { open(.health) } }
                )
                PopoverTelemetryRow(
                    icon: "clock.fill",
                    tint: .bbMint,
                    label: "今日离电",
                    value: reports.displayTodayBatterySeconds.map { UsageTimeFormat.duration($0) } ?? "—",
                    unit: "",
                    action: requestOpenMainWindow.map { open in { open(.battery) } }
                )
            }

            hairlineDivider

            // 4. 轻量操作栏（NSPopover 自身已是原生玻璃浮层，内部不叠加 .glass，避免 Glass-on-Glass）
            HStack(spacing: 8) {
                Button {
                    requestOpenMainWindow?(.overview)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "macwindow")
                            .font(.system(size: 11, weight: .semibold))
                        Text("打开概览")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 1)
                }
                .adaptiveCapsuleGlassButton(tint: .bbBlue)
                .controlSize(.regular)

                Button {
                    requestOpenMainWindow?(.energy)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                        Text("功耗分析")
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 1)
                }
                .adaptiveCapsuleGlassButton()
                .controlSize(.regular)

                Button {
                    requestOpenMainWindow?(.settings)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 12, weight: .medium))
                        .frame(width: 18, height: 18)
                }
                .adaptiveCapsuleGlassButton()
                .controlSize(.regular)
                .accessibilityLabel("打开设置")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: 312)
        .environment(sampler)
    }

    private func headerBadge(
        presentation: PowerStatePresentation,
        level: Double?
    ) -> (text: String, icon: String?, tint: Color) {
        if presentation.mode == .battery, let level, BatteryLevelPresentation.percent(level) <= 20 {
            return ("低电量", "exclamationmark.triangle.fill", .red)
        }
        if presentation.mode == .charging {
            return ("充电中", nil, .bbAmber)
        }
        if presentation.mode == .unknown {
            return ("读取中", nil, .secondary)
        }
        // 避免与下方主标题重复“电池供电 / 电源供电”，顶栏胶囊补充电池健康快览。
        let health = sampler.healthMetric
        if health.percent > 0 {
            return ("健康 \(Int(health.percent.rounded()))%", "battery.100percent", .bbMint)
        }
        return (compactStateLabel(presentation.mode), nil, presentation.tint)
    }

    @ViewBuilder
    private func popoverRuntimeText(mode: PowerStatePresentation.Mode, chargingGoal: Int?) -> some View {
        if mode == .battery {
            if let estimate = sampler.dischargeEstimate ?? sampler.systemReportedEstimate {
                let suffix = estimate.basis == .systemReported ? " · 系统估算" : ""
                Label(
                    "预计可用 \(UsageTimeFormat.duration(estimate.valueHours * 3_600))\(suffix)",
                    systemImage: "clock"
                )
                .font(BBType.caption)
                .foregroundStyle(Color.bbMint)
                .lineLimit(1)
            } else {
                Label("续航估算中", systemImage: "clock")
                    .font(BBType.caption)
                    .foregroundStyle(.secondary)
            }
        } else if mode == .charging {
            if let estimate = sampler.preferredChargeEstimate,
               let goal = estimate.goalPercent {
                let duration = UsageTimeFormat.duration(estimate.valueHours * 3_600)
                let targetText = Int(goal) >= 100 ? "充满" : "达 \(Int(goal))%"
                let suffix = estimate.basis == .systemReported ? " · 系统估算" : ""
                Label(
                    "预计 \(duration) 后\(targetText)\(suffix)",
                    systemImage: "bolt.badge.clock"
                )
                .font(BBType.caption)
                .foregroundStyle(Color.bbAmber)
                .lineLimit(1)
            } else {
                let pendingText: String = if let chargingGoal, chargingGoal < 100 {
                    "达 \(chargingGoal)% 时间估算中"
                } else {
                    "充满时间估算中"
                }
                Label(pendingText, systemImage: "bolt.badge.clock")
                    .font(BBType.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        } else if mode == .external {
            Label("外接电源直供", systemImage: "powerplug.fill")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private func conciseDetail(presentation: PowerStatePresentation, target: Int?) -> String {
        switch presentation.mode {
        case .external:
            if sampler.currentChargingBehaviorObservation?.reason == .thermalProtection {
                return "温度保护暂停充电"
            }
            if let behavior = sampler.currentChargingBehaviorObservation, behavior.state == .otherConfirmedPause {
                return behavior.displayLabel
            }
            if let target, sampler.currentLevel.isFinite, sampler.currentLevel >= Double(target) {
                return target == 100 ? "电池已充满 · 未充电" : "已达上限 \(target)% · 未充电"
            }
            return "电池当前未充电"
        default:
            return presentation.detail
        }
    }

    private var hairlineDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(scheme == .dark ? 0.12 : 0.08))
            .frame(height: 0.75)
    }

    private func compactStateLabel(_ mode: PowerStatePresentation.Mode) -> String {
        switch mode {
        case .charging: "充电中"
        case .battery: "电池供电"
        case .external: "电源供电"
        case .unknown: "读取中"
        }
    }
}

/// 弹窗内可悬停直达详情页的遥测行：悬停微亮与轻推箭头。
private struct PopoverTelemetryRow: View {
    let icon: String
    let tint: Color
    let label: String
    let value: String
    let unit: String
    var action: (() -> Void)?
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovered = false

    var body: some View {
        Group {
            if let action {
                Button(action: action) { rowContent }
                    .buttonStyle(ProductPressStyle())
                    .onHover { hovered = $0 }
            } else {
                rowContent
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var rowContent: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 20, height: 20)
                .background(
                    tint.opacity(hovered ? (scheme == .dark ? 0.24 : 0.18) : (scheme == .dark ? 0.16 : 0.11)),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )
            Text(label)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.bbInk.opacity(hovered ? 0.98 : 0.84))
            Spacer(minLength: 8)
            HStack(alignment: .firstTextBaseline, spacing: 2.5) {
                Text(value)
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Color.bbInk)
                if !unit.isEmpty {
                    Text(unit)
                        .font(BBType.caption)
                        .foregroundStyle(.secondary)
                }
            }
            if action != nil {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.secondary.opacity(hovered ? 0.85 : 0.28))
                    .offset(x: hovered && !reduceMotion ? 1.5 : 0)
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered ? Color.primary.opacity(scheme == .dark ? 0.09 : 0.055) : .clear)
        )
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : ProductMotion.hover, value: hovered)
    }
}
