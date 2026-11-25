import SwiftUI

struct SettingsView: View {
    @Environment(PowerSampler.self) private var sampler
    @Environment(LoginItemState.self) private var loginItem
    @Environment(\.isSectionActive) private var isSectionActive
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var needsCountReload = false
    @State private var localSnapshotCount = 0
    @State private var healthRecordCount = 0

    var body: some View {
        VStack(spacing: 0) {
            ProductPageHeader(
                title: "设置",
                subtitle: "应用行为、采样与本机数据",
                systemImage: "gearshape.fill",
                tint: .bbBlue
            )
            ScrollView {
                VStack(alignment: .leading, spacing: BBDesign.sectionSpacing) {
                    generalAndNotificationsCard
                    AdvancedSamplingCard(sampler: sampler, showRemovalControl: true)
                    localDataSection
                }
                .padding(.horizontal, BBDesign.pagePadding)
                .padding(.bottom, 28)
                .frame(maxWidth: BBDesign.formMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .productScrollEdges()
        }
        .task {
            await reloadLocalCountsAsync()
            loginItem.refresh()
        }
        .onChange(of: isSectionActive) { _, active in
            guard active else { return }
            loginItem.refresh()
            if needsCountReload {
                Task { await reloadLocalCountsAsync() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .batterySnapshotsDidChange)) { _ in
            if isSectionActive {
                Task { await reloadLocalCountsAsync() }
            } else {
                needsCountReload = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .batteryHealthHistoryDidChange)) { _ in
            if isSectionActive {
                Task { await reloadLocalCountsAsync() }
            } else {
                needsCountReload = true
            }
        }
    }

    // MARK: - 1. 常规与提醒（启动项 + 通知）

    private var generalAndNotificationsCard: some View {
        let notifier = NotificationManager.shared
        return VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "常规与提醒", systemImage: "bell.badge.fill", tint: .bbBlue)

            VStack(spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("开机时自动启动")
                            .font(BBType.bodyMedium)
                            .foregroundStyle(Color.bbInk)
                        Text(loginItem.statusSubtitle)
                            .font(BBType.caption)
                            .foregroundStyle(loginItem.needsApproval ? .orange : .secondary)
                    }
                    Spacer()
                    Toggle(
                        "",
                        isOn: Binding(
                            get: { loginItem.isOn },
                            set: { newValue in _ = loginItem.setEnabled(newValue) }
                        )
                    )
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                if loginItem.needsApproval {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 11))
                        Text("已在登录项中提出请求，需要在系统设置的登录项里允许后才会生效")
                            .font(BBType.caption)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("打开系统设置") { loginItem.openApprovalSettings() }
                            .adaptiveGlassButton(tint: .orange)
                            .controlSize(.small)
                    }
                    .foregroundStyle(.orange)
                    .productWell(tint: .orange, padding: 10)
                    .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
                }

                if let message = loginItem.lastErrorMessage {
                    Text(message)
                        .font(BBType.caption)
                        .foregroundStyle(.red)
                        .transition(reduceMotion ? .identity : .opacity)
                }

                Divider().opacity(0.45)

                notificationToggle(
                    title: "低电量提醒",
                    detail: "电量 ≤ 20% 且未接电时提醒",
                    isOn: Binding(
                        get: { notifier.lowBatteryEnabled },
                        set: { newValue in
                            Task { @MainActor in await notifier.setLowBatteryEnabled(newValue) }
                        }
                    )
                )

                notificationToggle(
                    title: "充电目标提醒",
                    detail: "充电达到系统设定上限并停止充电时提醒",
                    isOn: Binding(
                        get: { notifier.fullChargeEnabled },
                        set: { newValue in
                            Task { @MainActor in await notifier.setFullChargeEnabled(newValue) }
                        }
                    )
                )

                authorizationRow

                if let message = notifier.lastErrorMessage {
                    Text(message)
                        .font(BBType.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .productCard(accent: .bbBlue)
        .animation(reduceMotion ? nil : ProductMotion.reveal, value: loginItem.needsApproval)
        .animation(reduceMotion ? nil : ProductMotion.reveal, value: loginItem.lastErrorMessage)
        .animation(reduceMotion ? nil : ProductMotion.reveal, value: notifier.lastErrorMessage)
        .onAppear {
            Task { @MainActor in await notifier.refreshAuthorization() }
        }
    }

    private func notificationToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(BBType.bodyMedium).foregroundStyle(Color.bbInk)
                Text(detail)
                    .font(BBType.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }

    private var authorizationRow: some View {
        let notifier = NotificationManager.shared
        let denied = notifier.authorizationState == .denied
        return HStack(spacing: 10) {
            BrandSymbol(
                systemImage: denied ? "bell.slash.fill" : "bell.fill",
                tint: denied ? .red : .bbAmber,
                size: 26
            )
            VStack(alignment: .leading, spacing: 2) {
                Text("系统通知授权")
                    .font(BBType.caption)
                    .foregroundStyle(.secondary)
                Text(authorizationText(notifier.authorizationState))
                    .font(BBType.captionMedium)
                    .foregroundStyle(denied ? .red : Color.bbInk)
            }
            Spacer()
            if denied {
                Button("打开系统设置") { openSystemNotificationSettings() }
                    .adaptiveGlassButton(tint: .red)
                    .controlSize(.small)
            }
        }
        .productWell(tint: denied ? .red : .bbAmber, padding: 10)
    }

    private func authorizationText(_ state: NotificationAuthorization) -> String {
        switch state {
        case .authorized: "已允许"
        case .provisional: "已允许（临时）"
        case .ephemeral: "已允许（一次性）"
        case .denied: "已拒绝 — 需在系统设置中允许后才能收到提醒"
        case .notDetermined: "未授权 — 开启提醒时将请求系统通知权限"
        }
    }

    private func openSystemNotificationSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - 3. 本机数据

    private var localDataSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "本机数据", systemImage: "internaldrive.fill", tint: .bbTeal)

            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                spacing: 10
            ) {
                localDataTiles
            }

            Text("电池健康与每日汇总永久保留，详细使用曲线保留 30 天，近期功耗与温度曲线保留 24 小时。全部数据仅保存在本机。")
                .font(BBType.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            ProductDisclosure("采样与存储诊断") {
                VStack(spacing: 8) {
                    cadenceRow("窗口可见刷新", value: "每 \(Int(SamplingCadence.foregroundInterval)) 秒", tint: .secondary)
                    cadenceRow("后台刷新", value: "每 \(Int(SamplingCadence.backgroundInterval)) 秒", tint: .secondary)
                    cadenceRow("历史记录写入", value: "每 \(Int(SamplingCadence.historyInterval)) 秒", tint: .secondary)
                    cadenceRow(
                        "CPU / GPU / 内存分项",
                        value: sampler.helperEnabled
                            ? "功耗页按需每 \(Int(SamplingCadence.componentPowerInterval)) 秒"
                            : "已关闭",
                        tint: sampler.helperEnabled ? .bbAmber : .secondary
                    )
                    cadenceRow("电源插拔 / 低电量模式 / 热压力", value: "系统事件立即读取", tint: .secondary)
                    cadenceRow("近期功耗采样点", value: "\(localSnapshotCount) 条", tint: .bbBlue)
                    PollingHeartbeat(sampler: sampler)
                }
                .padding(.top, 8)
                .padding(.horizontal, 6)
            }
        }
        .productCard(accent: .bbTeal)
    }

    @ViewBuilder
    private var localDataTiles: some View {
        StatTile(icon: "heart.fill", tint: .bbMint, value: "\(healthRecordCount)", unit: "天", label: "健康记录")
        StatTile(icon: "calendar", tint: .bbTeal, value: "30", unit: "天", label: "使用明细")
        StatTile(icon: "clock.arrow.circlepath", tint: .bbAmber, value: "24", unit: "小时", label: "功耗趋势")
    }

    private func cadenceRow(_ label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Circle().fill(tint).frame(width: 6, height: 6)
            Text(label).font(BBType.caption).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.bbInk)
        }
    }

    @MainActor
    private func reloadLocalCountsAsync() async {
        needsCountReload = false
        let (snapshots, healthDays) = await Task.detached(priority: .utility) {
            (
                DataStore.shared.localSnapshots().count,
                DataStore.shared.healthHistory().count
            )
        }.value
        guard !Task.isCancelled else { return }
        localSnapshotCount = snapshots
        healthRecordCount = healthDays
    }
}

/// 只让这一行跟随每次成功轮询失效，避免设置页其余表单每秒重建。
private struct PollingHeartbeat: View {
    let sampler: PowerSampler

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(Color.bbBlue).frame(width: 6, height: 6)
            Text("上次成功读取").font(BBType.caption).foregroundStyle(.secondary)
            Spacer()
            Text(sampler.lastUpdateTime, format: .dateTime.hour().minute().second())
                .font(.system(size: 11.5, weight: .semibold, design: .rounded).monospacedDigit())
                .foregroundStyle(Color.bbInk)
        }
    }
}
