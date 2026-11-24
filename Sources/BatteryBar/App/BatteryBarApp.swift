import SwiftUI
import AppKit
import ServiceManagement

@main
struct BatteryBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        // 主窗口优先由 WindowGroup 提供原生玻璃窗口；未建立 SwiftUI 场景时，
        // AppDelegate 使用同一内容的保留 NSWindow 兜底，保证菜单栏入口始终可用。
        // sampler 由 AppDelegate 持有，状态栏/主窗口/popover 共用同一实例。
        WindowGroup(id: "main") {
            appDelegate.mainWindowContent()
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 940, height: 660)
        .commands {
            // 单实例工具：移除「文件 → 新建窗口」与 Cmd+N 多开入口，保证主窗口
            // 全程至多一个，关闭后经状态栏右键菜单 / Popover「查看详情」重开。
            CommandGroup(replacing: .newItem) {}
            CommandMenu("导航") {
                Button("概览") { appDelegate.navigation.go(.overview) }
                    .keyboardShortcut("1", modifiers: .command)
                Button("功耗") { appDelegate.navigation.go(.energy) }
                    .keyboardShortcut("2", modifiers: .command)
                Button("电池") { appDelegate.navigation.go(.battery) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("设置") { appDelegate.navigation.go(.settings) }
                    .keyboardShortcut("4", modifiers: .command)
            }
        }
    }

    // 图标由 Info.plist 声明的正式资源提供，不覆盖系统 applicationIconImage。
}

/// AppDelegate — 状态栏（左键 Popover / 右键菜单）、开机自启与主窗口兜底。
@MainActor
class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private static let mainWindowIdentifier = NSUserInterfaceItemIdentifier("BatteryArchiveMainWindow")

    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var aboutWindow: NSWindow?
    private var observer: NSObjectProtocol?
    private var loginItemActivationObserver: NSObjectProtocol?
    private var usageObserver: NSObjectProtocol?
    private var timeZoneObserver: NSObjectProtocol?
    private var mainWindowObservers: [NSObjectProtocol] = []
    /// SwiftUI 场景 action 优先用于首次打开；原生窗口保留后负责稳定重开。
    private var openMainWindowAction: (() -> Void)?
    private var mainWindow: NSWindow?
    private var mainWindowOpenGeneration: UInt64 = 0
    private var isOpeningMainWindow = false
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
            .background(OpenWindowRelay())
            .onAppear { [weak self] in
                guard let self else { return }
                self.sampler.start()
                self.sampler.setReadingSurface(.mainWindow, visible: true)
                self.registerMainWindow(Self.findVisibleMainWindow())
                self.refreshUsageReport()
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            .onDisappear { [weak self] in
                guard let self else { return }
                self.sampler.setReadingSurface(.mainWindow, visible: false)
                NSApp.setActivationPolicy(.accessory)
            }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        presentMainWindow()
        return false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        sampler.start()
        usageObserver = NotificationCenter.default.addObserver(
            forName: .batteryUsageDidChange, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refreshUsageReport() } }
        timeZoneObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.usageReport.syncSystemTimeZoneIfFollowing()
                self.refreshUsageReport()
            }
        }
        refreshUsageReport()
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

        // 创建 popover（匹配 312pt 轻量布局并随内容自动贴合高度，消除多余留白）
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self
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

        // 主窗口归 WindowGroup 管理：发通知由 MainWindowView 内的 openWindow 打开
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

    /// 状态栏菜单与 Popover 共用：优先前置现存窗口，其次请求 SwiftUI 场景，
    /// 并在场景 action 未注册或未实际打开窗口时使用保留的原生窗口兜底。
    private func presentMainWindow() {
        let visibleWindow = Self.findVisibleMainWindow()
        let retainedWindow = mainWindow.flatMap { $0.contentView == nil ? nil : $0 }
        let route = MainWindowPresentationStrategy.route(
            hasVisibleWindow: visibleWindow != nil,
            hasRetainedWindow: retainedWindow != nil,
            hasSceneAction: openMainWindowAction != nil
        )

        switch route {
        case .focusVisibleWindow:
            guard let visibleWindow else { return }
            registerMainWindow(visibleWindow)
            showMainWindow(visibleWindow)
        case .restoreRetainedWindow:
            guard let retainedWindow else { return }
            showMainWindow(retainedWindow)
        case .openSwiftUIScene:
            guard !isOpeningMainWindow else { return }
            guard let action = openMainWindowAction else {
                presentNativeMainWindow()
                return
            }
            isOpeningMainWindow = true
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
            mainWindowOpenGeneration &+= 1
            let generation = mainWindowOpenGeneration
            action()
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(750))
                guard let self, self.mainWindowOpenGeneration == generation else { return }
                if let window = Self.findVisibleMainWindow() {
                    self.registerMainWindow(window)
                } else {
                    self.presentNativeMainWindow()
                }
            }
        case .createNativeWindow:
            presentNativeMainWindow()
        }
    }

    /// 场景级 openWindow action 的注册入口（由 OpenWindowRelay.onAppear 调用）
    func registerOpenMainWindowAction(_ action: @escaping () -> Void) {
        openMainWindowAction = action
    }

    private func registerMainWindow(_ window: NSWindow?) {
        guard let window, window.frame.width > 500, window.contentView != nil else { return }
        window.identifier = Self.mainWindowIdentifier
        window.isReleasedWhenClosed = false
        if mainWindow !== window {
            mainWindow = window
            observeMainWindowLifecycle(window)
        }
        isOpeningMainWindow = false
        mainWindowOpenGeneration &+= 1
    }

    private func observeMainWindowLifecycle(_ window: NSWindow) {
        let center = NotificationCenter.default
        for token in mainWindowObservers {
            center.removeObserver(token)
        }
        mainWindowObservers.removeAll(keepingCapacity: true)
        mainWindowObservers.append(center.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sampler.setReadingSurface(.mainWindow, visible: false)
                NSApp.setActivationPolicy(.accessory)
            }
        })
        mainWindowObservers.append(center.addObserver(
            forName: NSWindow.didMiniaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sampler.setReadingSurface(.mainWindow, visible: false)
            }
        })
        mainWindowObservers.append(center.addObserver(
            forName: NSWindow.didDeminiaturizeNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.sampler.setReadingSurface(.mainWindow, visible: true)
                self.refreshUsageReport()
            }
        })
    }

    private func showMainWindow(_ window: NSWindow) {
        isOpeningMainWindow = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        sampler.start()
        sampler.setReadingSurface(.mainWindow, visible: true)
        refreshUsageReport()
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    private func presentNativeMainWindow() {
        if let mainWindow, mainWindow.contentView != nil {
            showMainWindow(mainWindow)
            return
        }

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
        window.isReleasedWhenClosed = false
        if !window.setFrameAutosaveName("BatteryArchiveMainWindow") {
            window.center()
        }
        window.contentViewController = NSHostingController(rootView: mainWindowContent())
        mainWindow = window
        observeMainWindowLifecycle(window)
        isOpeningMainWindow = false
        mainWindowOpenGeneration &+= 1
        showMainWindow(window)
    }

    /// Popover「查看详情」入口：先收起弹窗再呈现主窗口（同一权威路径）
    func openMainWindowFromPopover() {
        popover?.performClose(nil)
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(120))
            self?.presentMainWindow()
        }
    }

    /// 查找已存在的可见主窗口（SwiftUI WindowGroup 创建的 MainWindowView 所在窗口）。
    /// 排除 MenuBarExtra popover（私有类名特征）、About 面板（380 宽）与
    /// 状态栏 Popover（312 宽）：优先按稳定窗口 identifier 匹配，回退 frame.width > 500。
    static func findVisibleMainWindow() -> NSWindow? {
        NSApp.windows.first { window in
            let className = String(describing: type(of: window))
            if className.contains("MenuExtra") || className.contains("_NSMenuExtra") {
                return false
            }
            guard window.contentView != nil,
                  window.canBecomeKey,
                  !window.isMiniaturized,
                  window.isVisible else {
                return false
            }
            return window.identifier == mainWindowIdentifier || window.frame.width > 500
        }
    }

    @objc private func openBatterySettingsFromMenu(_ sender: Any?) {
        sampler.openBatterySettings()
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        if aboutWindow == nil {
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 380, height: 240),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.title = "关于 \(AppBrand.displayName)"
            window.isReleasedWhenClosed = false
            window.contentViewController = NSHostingController(rootView: AboutPanelView())
            aboutWindow = window
        }
        aboutWindow?.center()
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
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) {
        sampler.setReadingSurface(.statusPopover, visible: true)
        refreshUsageReport()
    }

    func popoverDidClose(_ notification: Notification) {
        sampler.setReadingSurface(.statusPopover, visible: false)
    }

    /// 更新状态栏文字（跟随系统逻辑：纯百分比，不显示预估时间）
    /// 低电量（≤20% 且未充电）时文字变红。
    ///
    /// 宽度控制：button.attributedTitle + 固定 statusItem.length（NSAttributedString 精确测宽 + ceil + 2pt）。
    /// 不再用 NSTextField 子视图方案——macOS 27 上 NSTextField 嵌入 NSStatusBarButton
    /// 会触发 AppKit 布局引擎持续重排，实测空转约 37% CPU（2026-08-22，见 T-30）。
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
        for token in mainWindowObservers {
            NotificationCenter.default.removeObserver(token)
        }
        mainWindowObservers.removeAll()
    }
}

/// 捕获 SwiftUI WindowGroup 的 openWindow action。
/// AppDelegate 同时保留窗口引用并提供 AppKit fallback，因 detached host 的 action 可能无效。
private struct OpenWindowRelay: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .onAppear {
                (NSApp.delegate as? AppDelegate)?
                    .registerOpenMainWindowAction { openWindow(id: "main") }
            }
    }
}
