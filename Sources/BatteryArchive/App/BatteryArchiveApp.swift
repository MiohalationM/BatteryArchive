import SwiftUI
import AppKit
import Darwin

@main
struct BatteryArchiveApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 菜单栏常驻应用：不声明 WindowGroup，避免启动时预创建隐藏主窗口与冗余窗口状态；
        // 主窗口、Popover 与关于窗口全部由 AppDelegate 按需创建并在关闭时彻底释放。
        Settings {
            EmptyView()
        }
    }

    // 图标由 Info.plist 声明的正式资源提供，不覆盖系统 applicationIconImage。
}

/// AppDelegate — 状态栏（左键 Popover / 右键菜单）、开机自启与按需窗口生命周期管理。
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("BatteryArchiveMainWindow")

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var aboutWindow: NSWindow?
    private var aboutWindowObserver: NSObjectProtocol?
    private var observer: NSObjectProtocol?
    private var loginItemActivationObserver: NSObjectProtocol?
    private var usageObserver: NSObjectProtocol?
    private var timeZoneObserver: NSObjectProtocol?
    private var mainWindowObservers: [NSObjectProtocol] = []
    private var mainWindow: NSWindow?
    private var reclaimMemoryTask: Task<Void, Never>?
    // refreshTitle 门控：文字与低电量态都没变时跳过（title/length 赋值会触发菜单栏重排）
    private var lastTitleText: String?
    private var lastTitleLowBattery = false

    let sampler = PowerSampler()
    let usageReport = UsageReportModel()
    let navigation = ProductNavigation()
    /// 开机自启动共享状态：右键菜单与设置页 Toggle 共用，禁止两套逻辑漂移
    let loginItem = LoginItemState()

    func mainWindowContent() -> some View {
        MainWindowView()
            .environment(sampler)
            .environment(loginItem)
            .environment(usageReport)
            .environment(navigation)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentMainWindow()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sampler.start()
        usageObserver = NotificationCenter.default.addObserver(
            forName: .batteryUsageDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.sampler.isForegroundReadingActive else { return }
                self.refreshUsageReport()
            }
        }
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.usageReport.syncSystemTimeZoneIfFollowing()
                if self.sampler.isForegroundReadingActive {
                    self.refreshUsageReport()
                }
            }
        }
        loginItem.refresh()

        // 通知设置初始化：只查询授权状态、绝不请求权限（策略见 NotificationManager）
        NotificationManager.shared.attachSystemPresentationDelegate()
        Task { @MainActor in
            await NotificationManager.shared.start()
        }

        // 应用重新激活后刷新系统设置中的真实状态。通知路径只查询授权，绝不请求权限。
        loginItemActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.loginItem.refresh()
                Task { @MainActor in
                    await NotificationManager.shared.refreshAuthorization()
                }
            }
        }

        // 初始用 variableLength，后续在 refreshTitle 中改为固定值
        let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        self.statusItem = statusItem

        if let button = statusItem.button {
            button.title = "—"
            button.image = nil
            button.font = NSFont.menuBarFont(ofSize: 0)
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            // 左键弹 Popover，右键弹菜单（在 statusItemClicked 中按事件类型分流）
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }

        // 监听 sampler 变化，更新文字（queue: .main 保证闭包在主线程，assumeIsolated 同步直达）
        observer = NotificationCenter.default.addObserver(
            forName: NSNotification.Name("PowerSamplerDidUpdate"),
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refreshTitle()
            }
        }

        // 仅保留轻量 NSPopover 外壳，按需打开时才挂载 SwiftUI 视图树，关闭后立即销毁释放内存
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
        popover.contentSize = NSSize(width: 312, height: 310)
        self.popover = popover

        // 启动时 sampler.start() 已同步完成首次读数，立即刷新状态栏；1 秒后保底再同步一次。
        refreshTitle()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.refreshTitle()
        }
    }

    private func refreshUsageReport() {
        let live = sampler.liveUsageBuckets()
        Task { @MainActor in await usageReport.refresh(live: live) }
    }

    private func cancelPendingMemoryReclaim() {
        reclaimMemoryTask?.cancel()
        reclaimMemoryTask = nil
    }

    private func releaseIdleUICachesAndReclaimMemory() {
        guard !sampler.isForegroundReadingActive else { return }
        usageReport.releaseDetailedCache()
        cancelPendingMemoryReclaim()
        reclaimMemoryTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard let self, !Task.isCancelled, !self.sampler.isForegroundReadingActive else { return }
            self.reclaimMemoryTask = nil
            _ = malloc_zone_pressure_relief(nil, 0)
        }
    }

    // MARK: - 状态栏点击分流（左键 Popover / 右键菜单）

    @objc func statusItemClicked(_ sender: Any?) {
        guard let event = NSApp.currentEvent else {
            togglePopover(sender)
            return
        }
        switch event.type {
        case .rightMouseUp, .rightMouseDown:
            guard let item = statusItem else { return }
            // 临时挂载菜单让系统显示它，显示完移除，恢复左键 Popover 行为
            item.menu = buildStatusMenu()
            item.button?.performClick(nil)
            item.menu = nil
        default:
            // Option+左键直达主窗口，普通左键切换轻量 Popover
            if event.modifierFlags.contains(.option) {
                popover?.performClose(nil)
                presentMainWindow()
            } else {
                togglePopover(sender)
            }
        }
    }

    private func buildStatusMenu() -> NSMenu {
        self.loginItem.refresh()
        let menu = NSMenu()

        // 主窗口由 AppDelegate 按需创建，关闭时彻底释放视图树
        let openItem = menu.addItem(withTitle: "打开主窗口", action: #selector(openMainWindowFromMenu(_:)), keyEquivalent: "")
        openItem.target = self

        let loginItem = menu.addItem(withTitle: "开机自启动", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        loginItem.target = self
        // 与设置页 Toggle 共用同一 LoginItemState；requiresApproval 不得假装已开启
        if self.loginItem.isOn {
            loginItem.state = .on
        } else {
            loginItem.state = .off
            if self.loginItem.needsApproval {
                loginItem.title = "开机自启动（需要在系统设置中允许）"
            }
        }

        menu.addItem(.separator())

        let settingsItem = menu.addItem(withTitle: "系统电池设置…", action: #selector(openBatterySettingsFromMenu(_:)), keyEquivalent: "")
        settingsItem.target = self

        let aboutItem = menu.addItem(withTitle: "关于 \(AppBrand.displayName)", action: #selector(showAbout(_:)), keyEquivalent: "")
        aboutItem.target = self

        menu.addItem(.separator())

        // target 为 nil 走响应链，最终由 NSApplication 处理 terminate
        menu.addItem(withTitle: "退出 \(AppBrand.displayName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return menu
    }

    @objc private func openMainWindowFromMenu(_ sender: Any?) {
        presentMainWindow()
    }

    /// 状态栏菜单与 Popover 共用：已显示则前置，最小化则还原，否则按需创建原生主窗口。
    private func presentMainWindow() {
        cancelPendingMemoryReclaim()
        let hasVisible = mainWindow.map { $0.isVisible && !$0.isMiniaturized } ?? false
        let hasMinimized = mainWindow?.isMiniaturized ?? false
        let route = MainWindowPresentationStrategy.route(
            hasVisibleWindow: hasVisible,
            hasMinimizedWindow: hasMinimized
        )

        switch route {
        case .focusVisibleWindow, .deminiaturizeWindow:
            guard let mainWindow else {
                presentNativeMainWindow()
                return
            }
            showMainWindow(mainWindow)
        case .createNativeWindow:
            presentNativeMainWindow()
        }
    }

    private func clearMainWindowObservers() {
        let center = NotificationCenter.default
        for token in mainWindowObservers {
            center.removeObserver(token)
        }
        mainWindowObservers.removeAll(keepingCapacity: false)
    }

    private func clearAboutWindowObserver() {
        if let token = aboutWindowObserver {
            NotificationCenter.default.removeObserver(token)
            aboutWindowObserver = nil
        }
    }

    private func observeMainWindowLifecycle(_ window: NSWindow) {
        clearMainWindowObservers()
        let center = NotificationCenter.default
        mainWindowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak window] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clearMainWindowObservers()
                self.sampler.setPowerPageVisible(false)
                self.sampler.setReadingSurface(.mainWindow, visible: false)
                window?.contentViewController = nil
                if self.mainWindow === window {
                    self.mainWindow = nil
                }
                NSApp.setActivationPolicy(.accessory)
                self.releaseIdleUICachesAndReclaimMemory()
            }
        })
        mainWindowObservers.append(center.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sampler.setPowerPageVisible(false)
                self.sampler.setReadingSurface(.mainWindow, visible: false)
                self.releaseIdleUICachesAndReclaimMemory()
            }
        })
        mainWindowObservers.append(center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.cancelPendingMemoryReclaim()
                self.sampler.setReadingSurface(.mainWindow, visible: true)
                self.sampler.setPowerPageVisible(self.navigation.section == .energy)
                self.refreshUsageReport()
            }
        })
    }

    private func showMainWindow(_ window: NSWindow) {
        cancelPendingMemoryReclaim()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        sampler.start()
        sampler.setReadingSurface(.mainWindow, visible: true)
        sampler.setPowerPageVisible(navigation.section == .energy)
        refreshUsageReport()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func presentNativeMainWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 660),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.identifier = Self.mainWindowIdentifier
        window.title = AppBrand.displayName
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.contentMinSize = NSSize(width: 840, height: 580)
        // ARC 强引用由 willCloseNotification 主动清零释放，必须设为 false 避免 AppKit 重复 release 崩溃；
        // 清空 contentViewController 与 self.mainWindow 后 NSWindow 会立即 deinit。
        window.isReleasedWhenClosed = false
        if !window.setFrameUsingName("BatteryArchiveMainWindow") {
            window.center()
        }
        window.setFrameAutosaveName("BatteryArchiveMainWindow")
        window.contentViewController = NSHostingController(rootView: mainWindowContent())
        mainWindow = window
        observeMainWindowLifecycle(window)
        showMainWindow(window)
    }

    /// Popover 跳转入口：先收起弹窗再呈现主窗口（同一权威路径）
    func openMainWindowFromPopover() {
        cancelPendingMemoryReclaim()
        popover?.performClose(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.presentMainWindow()
        }
    }

    @objc private func openBatterySettingsFromMenu(_ sender: Any?) {
        sampler.openBatterySettings()
    }

    @objc private func showAbout(_ sender: Any?) {
        cancelPendingMemoryReclaim()
        NSApp.activate(ignoringOtherApps: true)
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "关于 \(AppBrand.displayName)"
            // 同主窗口：由 ARC 强引用配合 willCloseNotification 清零实现安全释放
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AboutPanelView())
            window.center()
            aboutWindow = window
            clearAboutWindowObserver()
            aboutWindowObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification, object: window, queue: .main
            ) { [weak self, weak window] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.clearAboutWindowObserver()
                    window?.contentViewController = nil
                    if self.aboutWindow === window {
                        self.aboutWindow = nil
                    }
                    self.releaseIdleUICachesAndReclaimMemory()
                }
            }
        }
        aboutWindow?.makeKeyAndOrderFront(nil)
    }

    // MARK: - 开机自启动（与设置页共用 LoginItemState）

    @objc private func toggleLoginItem(_ sender: Any?) {
        loginItem.refresh()
        if let message = loginItem.setEnabled(!loginItem.isOn) {
            let alert = NSAlert()
            alert.messageText = "开机自启动设置失败"
            alert.informativeText = "\(message)\n若系统要求批准，请在「系统设置 → 通用 → 登录项」中允许\(AppBrand.displayName)。"
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    // MARK: - Popover

    @objc func togglePopover(_ sender: Any?) {
        guard let popover = popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            cancelPendingMemoryReclaim()
            let popoverController = NSHostingController(
                rootView: StatusPopover(
                    sampler: sampler,
                    requestOpenMainWindow: { [weak self] destination in
                        self?.navigation.go(destination)
                        self?.openMainWindowFromPopover()
                    }
                )
                .environment(usageReport)
            )
            popoverController.sizingOptions = .preferredContentSize
            popover.contentViewController = popoverController
            popover.contentSize = NSSize(width: 312, height: 310)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        cancelPendingMemoryReclaim()
        sampler.setReadingSurface(.statusPopover, visible: true)
        refreshUsageReport()
    }

    func popoverDidClose(_ notification: Notification) {
        sampler.setReadingSurface(.statusPopover, visible: false)
        popover?.contentViewController = nil
        releaseIdleUICachesAndReclaimMemory()
    }

    /// 更新状态栏文字（跟随系统逻辑：纯百分比，不显示预估时间）
    /// 低电量（≤20% 且未充电）时文字变红。
    ///
    /// 宽度控制：button.attributedTitle + 固定 statusItem.length（NSAttributedString 精确测宽 + ceil + 2pt）。
    /// 不再用 NSTextField 子视图方案——macOS 27 上 NSTextField 嵌入 NSStatusBarButton
    /// 会触发 AppKit 布局引擎持续重排，造成明显的空闲 CPU 占用。
    private func refreshTitle() {
        let level = BatteryLevelPresentation.percent(sampler.currentLevel)
        let text = sampler.currentSourceKnown ? "\(level)%" : "—"
        let lowBattery = sampler.currentSourceKnown && level <= 20 && !sampler.currentExternalConnected

        // 每秒采样通知到达，但内容未变时跳过：title/length 赋值会触发菜单栏重排
        guard text != lastTitleText || lowBattery != lastTitleLowBattery else { return }
        lastTitleText = text
        lastTitleLowBattery = lowBattery

        guard let button = statusItem?.button else { return }
        let font = NSFont.menuBarFont(ofSize: 0)
        // 低电量变红；labelColor 为动态色，自动跟随系统深浅模式
        let color: NSColor = lowBattery ? .systemRed : .labelColor
        button.attributedTitle = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color])
        // 精确宽度：attributed size（含字体全要素）→ ceil 防小数裁切 + 2pt 余量防 % 边缘被裁
        let width = ceil(NSAttributedString(string: text, attributes: [.font: font]).size().width) + 2
        statusItem?.length = width
    }

    func applicationWillTerminate(_ notification: Notification) {
        cancelPendingMemoryReclaim()
        sampler.stop()
        // stop 触发的最后一次 async 落盘必须赶在进程结束前完成：
        // 串行队列排空后再放行终止，防止退出丢 usage-history/journal 尾行
        DataStore.shared.flushNow()
        if let o = observer {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = loginItemActivationObserver {
            NotificationCenter.default.removeObserver(o)
        }
        if let o = usageObserver { NotificationCenter.default.removeObserver(o) }
        if let o = timeZoneObserver { NotificationCenter.default.removeObserver(o) }
        clearMainWindowObservers()
        clearAboutWindowObserver()
    }
}
