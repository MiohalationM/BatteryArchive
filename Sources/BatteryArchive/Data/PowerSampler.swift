import Foundation
import Observation
import IOKit.ps
import CoreGraphics

/// 采样与 UI 状态中枢。
///
/// 隔离模型：整个类隔离在 MainActor，@Observable 状态只允许主线程变更，
/// 消除旧实现 `@unchecked Sendable` 下定时器 / 后台队列并发写状态的数据竞争。
/// SwiftUI 通过 Observation 属性级追踪订阅：视图 body 读到哪个属性，就只在
/// 哪个属性变化时失效——页面根视图不读瓦片等高频字段，历史 Chart 因此不被
/// 高频采样带着重建。阻塞调用（system_profiler 健康度等）
/// 通过 Task.detached 移出主线程，结果回写主线程；休眠回调用 MainActor.assumeIsolated
/// 同步执行，避免 willSleep 到系统入睡之间 Task 排队延迟导致睡眠统计丢失。
///
/// 固定采样节奏（无用户可调刷新频率）：
/// - 任一读数界面可见：基础兜底读取每 5 秒；都不可见：每 15 秒；
/// - 每次界面打开立即读取一次；
/// - IOPowerSources 变化（电源增删/插拔）经 IOPSNotificationCreateRunLoopSource
///   立即读取；低电量模式与热压力走 ProcessInfo 系统通知立即更新；
/// - 通知风暴按约 180ms 合并；stop 之后的事件回调不得写状态；
///   基础读取全部在主线程同步执行，天然串行、不可能重叠。
/// IORegistry 功率/温度没有可靠公开逐字段通知，因此保留兜底轮询。
@MainActor
@Observable
final class PowerSampler {
    @ObservationIgnored private let reader = BatteryReader()
    @ObservationIgnored private let dataStore: DataStore
    @ObservationIgnored private var usageAggregator: UsageTelemetryAggregator
    @ObservationIgnored private var usageScreenOn: Bool?
    @ObservationIgnored private var lastUsagePublishMinute: Int?
    @ObservationIgnored private var lastUsageExternal: Bool?
    @ObservationIgnored private let sleepWatcher = SleepWatcher()
    @ObservationIgnored private let chargePolicyMonitor = ChargePolicyMonitor()
    @ObservationIgnored private var dispatchTimer: DispatchSourceTimer?
    @ObservationIgnored private var componentPowerTimer: DispatchSourceTimer?
    @ObservationIgnored private var storageTimer: Timer?
    @ObservationIgnored private var chargePolicyTimer: Timer?
    @ObservationIgnored private var liveReadingDemand = LiveReadingDemand()

    // MARK: 系统事件源
    @ObservationIgnored private var powerSourceRunLoopSource: CFRunLoopSource?
    /// IOPS 回调 C context 的清理句柄。box 由 CFRunLoopSource 的 context 以
    /// passRetained 持有（与 sampler 生命周期解耦，未配对 stop 释放后回调经
    /// 弱引用安全返回）；unregister/deinit 必须配对 release，防止泄漏或悬挂。
    /// nonisolated(unsafe)：deinit（非隔离上下文）需要兜底读取该句柄——
    /// 对象销毁时不存在并发访问，模式安全；正常读写均在 MainActor。
    @ObservationIgnored nonisolated(unsafe) private var iopsSourceCleanup: IOPSSourceCleanup?
    @ObservationIgnored nonisolated(unsafe) private var healthHistoryObserver: NSObjectProtocol?
    @ObservationIgnored private var systemEventObservers: [NSObjectProtocol] = []
    @ObservationIgnored private var baseReadingCoalescer = NotificationCoalescer()
    @ObservationIgnored private var pendingEventReadTask: Task<Void, Never>?

    private(set) var currentLevel: Double = 0
    private(set) var currentIsCharging: Bool = false
    /// 是否接外接电源。与 currentIsCharging 相互独立：
    /// 满电保持/优化充电暂停/80% 上限都是接电未充电。
    private(set) var currentExternalConnected: Bool = false
    private(set) var currentSourceKnown = false
    var statePresentation: PowerStatePresentation {
        PowerStatePresentation.resolve(
            external: currentSourceKnown ? currentExternalConnected : nil,
            charging: currentIsCharging, level: currentLevel,
            target: chargePolicySnapshot.expiring(at: Date(), ttl: ChargePolicyMonitor.cacheTTL).targetPercent,
            behavior: currentChargingBehaviorObservation)
    }
    /// 当前接电阶段的充电行为观察；读取缺口立即清空，原因回到未知。
    private(set) var currentChargingBehaviorObservation: ChargingBehaviorObservation?
    /// 系统配置/策略上限，独立于当前充电行为；目标不可用时为 nil。
    private(set) var chargePolicySnapshot = ChargePolicySnapshot.unavailable()
    private(set) var chargePolicyRevision = 0
    var pluggedNotChargingLabel: String {
        ChargingStatusPresentation.pluggedNotChargingLabel(
            observation: currentChargingBehaviorObservation,
            level: currentLevel,
            targetPercent: chargePolicySnapshot.expiring(at: Date(), ttl: ChargePolicyMonitor.cacheTTL).targetPercent
        )
    }
    /// 系统负载（瓦特）。接电且无系统遥测时为 0（currentPowerAvailable == false）
    private(set) var currentWattage: Double = 0
    /// 电池包充入/放出功率绝对值（瓦特）；方向由 currentIsCharging 表达
    private(set) var currentBatteryPower: Double = 0
    /// 本轮电池包功率是否真实可用（含可信 0W；false = 没有读到功率）
    private(set) var currentBatteryPowerAvailable = false
    private(set) var currentPowerAvailable = false
    private(set) var currentPowerIsEstimated = false
    private(set) var currentVoltage: Double = 0
    private(set) var currentAmperage: Double = 0
    private(set) var currentAdapterInputPower: Double = 0
    private(set) var currentAdapterInputAvailable = false
    /// 电池温度（°C）；按 0.05°C 阈值门控，避免无关读数触发视图重绘。
    private(set) var currentTemperature: Double? = nil
    private(set) var currentLowPowerModeEnabled = ProcessInfo.processInfo.isLowPowerModeEnabled
    private(set) var currentThermalState = "正常"
    private(set) var currentInfo: BatteryInfo?
    /// 健康口径：UI 首选 macOS system_profiler 报告的「最大容量」；
    /// FullChargeCapacity÷DesignCapacity 仅作回退并标注「容量比估算」，
    /// 不冒充系统健康度。Popover 与主窗口消费同一模型。
    private(set) var healthMetric = BatteryHealthMetric()
    /// 永久本机电池健康日台账（升序）；随 `.batteryHealthHistoryDidChange` 响应式刷新。
    private(set) var healthHistory: [BatteryHealthRecord] = []
    /// 系统健康读取的小时级 TTL 状态；读取本身后台执行，不进采样路径
    @ObservationIgnored private var lastSystemHealthFetchAt: Date?
    private static let systemHealthRefreshTTL: TimeInterval = 3600
    /// 后台静默采样期间记录的最新读取时间；切回前台时一次性回写，消除后台无语义变化的 @Observable 扰动。
    @ObservationIgnored private var latestBackgroundReadAt: Date?
    @ObservationIgnored private var latestBackgroundSuccessAt: Date?
    /// 最近一次基础读数轮询成功的时刻。只有明确读取它的小视图会跟随失效。
    private(set) var lastUpdateTime: Date = Date()
    private(set) var isForegroundReadingActive = false

    // MARK: 数据质量语义（功耗诊断区消费）
    private(set) var loadMetric = TelemetrySample<Double>.initial(nil, source: .unavailable, at: .distantPast)
    private(set) var batteryPowerMetric = TelemetrySample<Double>.initial(nil, source: .unavailable, at: .distantPast)
    private(set) var inputPowerMetric = TelemetrySample<Double>.initial(nil, source: .unavailable, at: .distantPast)
    private(set) var temperatureMetric = TelemetrySample<Double>.initial(nil, source: .unavailable, at: .distantPast)

    // MARK: 分钟聚合
    @ObservationIgnored private var aggregator = WindowTelemetryAggregator()

    private(set) var cpuPower: Double = 0
    private(set) var gpuPower: Double = 0
    private(set) var dramPower: Double = 0
    /// 最近一次成功的分项功耗采样时刻。超过约 30s 未更新视为陈旧，
    /// UI 只显示绝对瓦数、不再计算占比。
    private(set) var lastComponentPowerAt: Date = .distantPast

    // MARK: 续航/充电估算（RuntimeEstimator 结果；nil = 数据不足，正在校准）
    /// 离电续航 App 估算。置信度低于门槛时保持 nil。
    private(set) var dischargeEstimate: EstimationResult?
    /// 充电剩余时间 App 估算（按当前充电速度）。
    private(set) var chargeEstimate: EstimationResult?
    /// IOPowerSources 的系统剩余时间（独立证据，永不与 App 证据静默混算）
    private(set) var systemReportedEstimate: EstimationResult?
    /// IOPowerSources 的系统充满剩余时间（独立证据，仅在充电目标为 100% 时可用）
    private(set) var systemReportedChargeEstimate: EstimationResult?

    /// 最近完成的分钟聚合环形缓冲（估算器输入，硬上限）
    @ObservationIgnored private var recentAggregates: [MinuteAggregate] = []
    private static let recentAggregatesLimit = 120
    /// 上一轮读取的 IOPS 系统剩余时间（分钟）
    @ObservationIgnored private var lastSystemReportedMinutes: Int = -1
    /// 估算重算节流：除分钟快照/电源切换外最多每 30 秒一次
    @ObservationIgnored private var lastEstimateRecalcAt = Date.distantPast
    private static let estimateRecalcInterval: TimeInterval = 30

    /// Helper 服务开关（默认关闭，用户在 PowerAnalysisView 手动开启；只控制分项采样是否运行）。
    /// 开启后才会安装 Helper 并读取 CPU/GPU/内存分项功耗。
    private(set) var helperEnabled: Bool = UserDefaults.standard.object(forKey: "BatteryArchiveHelperEnabled") as? Bool ?? false
    /// Helper 生命周期状态机（可注入边界；关闭高级采样绝不卸载）
    private(set) var helperLifecycle: HelperLifecycleController
    /// 供 UI 读取的 Helper 生命周期状态
    var helperState: HelperLifecycleState { helperLifecycle.state }
    /// 供 UI 门控按钮/开关：涵盖正在进行中的特权安装/卸载操作
    var isHelperBusy: Bool { helperLifecycle.isBusy }
    /// 供设置页判断后台服务是否已安装（未安装时禁用“移除辅助服务…”）
    var isHelperInstalled: Bool { helperLifecycle.installedState != .notInstalled }

    @ObservationIgnored private var isComponentPowerSampleInFlight = false
    @ObservationIgnored private let helperClient = HelperClient()
    @ObservationIgnored private var componentGeneration: UInt64 = 0
    @ObservationIgnored private var componentTask: Task<Void, Never>?
    private(set) var cpuPowerAvailable = false
    private(set) var gpuPowerAvailable = false
    private(set) var dramPowerAvailable = false
    private(set) var componentPowerError: String?
    @ObservationIgnored private var isSleeping: Bool = false
    @ObservationIgnored private var areScreensSleeping: Bool = false
    @ObservationIgnored private var isStarted: Bool = false
    @ObservationIgnored private var chargeCompletionTracker = ChargeCompletionTracker()
    @ObservationIgnored private var estimateStateSince = Date()
    /// 高级采样开关持久化键
    private static let helperEnabledKey = "BatteryArchiveHelperEnabled"

    init(dataStore: DataStore = .shared) {
        self.dataStore = dataStore
        self.usageAggregator = UsageTelemetryAggregator(
            measurementEpoch: dataStore.usageMeasurementEpoch
        )
        self.helperLifecycle = HelperLifecycleController(ops: SystemHelperLifecycleOps(installer: HelperInstaller(), client: helperClient))
        self.healthHistory = dataStore.healthHistory()
        registerHealthHistoryObserver()
        chargePolicyMonitor.onChange = { [weak self] snapshot, revision in
            guard let self else { return }
            let changed = self.chargePolicySnapshot != snapshot || self.chargePolicyRevision != revision
            if self.chargePolicySnapshot != snapshot { self.chargePolicySnapshot = snapshot }
            if self.chargePolicyRevision != revision { self.chargePolicyRevision = revision }
            if self.isStarted, changed { self.recalculateEstimates() }
        }
    }

    func start() {
        guard !isStarted else { return }
        isStarted = true
        registerHealthHistoryObserver()
        reloadHealthHistory()
        usageAggregator = UsageTelemetryAggregator(measurementEpoch: dataStore.usageMeasurementEpoch)
        let displayAwake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        isSleeping = false
        usageScreenOn = displayAwake
        areScreensSleeping = !displayAwake
        lastUsagePublishMinute = nil
        lastUsageExternal = nil

        let reading = reader.readBatteryReading()
        estimateStateSince = Date()

        // 接线 SleepWatcher：通过系统休眠/唤醒事件维护 isSleeping 与睡眠时长，
        // 并在睡眠开始立即截断聚合器连续量
        sleepWatcher.onSleep = { [weak self] in
            MainActor.assumeIsolated { self?.handleSleep() }
        }
        sleepWatcher.onWake = { [weak self] in
            MainActor.assumeIsolated { self?.handleWake() }
        }
        sleepWatcher.onScreensSleep = { [weak self] in
            MainActor.assumeIsolated { self?.handleScreensSleep() }
        }
        sleepWatcher.onScreensWake = { [weak self] in
            MainActor.assumeIsolated { self?.handleScreensWake() }
        }
        sleepWatcher.start()

        registerSystemEventSources()

        if let reading {
            applyBaseReading(reading)
        }
        sampleStorage()
        // 启动策略监视器并拉取目标（独立于 5 秒基础采样，后台执行且最多一个进程）
        chargePolicyMonitor.start()
        chargePolicyMonitor.refreshIfNeeded()

        // 健康口径：先以 IORegistry 容量比作为「估算」回退占位（明确标注），
        // 随后后台读取 macOS 系统报告值（首选口径）覆盖；不因容量比>0 而跳过。
        // 不再在启动时额外 spawn system_profiler 拉取界面未展示的序列号/机型字段。
        applyFallbackHealth()
        refreshSystemHealthInBackground()

        // Helper 服务：启动时只做休眠态版本检查（不建立 XPC、不触发 launchd），
        // 绝不自动安装/升级/弹管理员授权。版本不匹配时持久化关闭运行态开关并停止
        // 分项采样；用户再次主动开启才会执行安装/更新。
        Task { @MainActor [weak self] in
            guard let self else { return }
            let state = await self.helperLifecycle.refreshAtStartup(enabled: self.helperEnabled)
            guard self.isStarted else { return }
            if self.helperEnabled, state != .enabled {
                self.persistAdvancedSamplingEnabled(false)
                self.helperEnabled = false
                self.stopComponentPowerTimer()
            } else if state == .enabled {
                self.restartComponentPowerTimer(sampleImmediately: true)
            }
        }

        // 存储定时器（Timer + target/selector 在主 RunLoop 触发，无隔离问题）
        let st = Timer(timeInterval: SamplingCadence.historyInterval, target: self, selector: #selector(fireStorage), userInfo: nil, repeats: true)
        RunLoop.main.add(st, forMode: .common)
        storageTimer = st

        let policyTimer = Timer(
            timeInterval: ChargePolicyMonitor.fallbackRefreshInterval,
            target: self,
            selector: #selector(fireChargePolicyRefresh),
            userInfo: nil,
            repeats: true
        )
        RunLoop.main.add(policyTimer, forMode: .common)
        chargePolicyTimer = policyTimer

        // 基础读数定时器
        restartTimer()
    }

    func stop() {
        guard isStarted else { return }
        isStarted = false
        usageAggregator.stop(at: Date(), monotonicTime: ProcessInfo.processInfo.systemUptime)
        dataStore.saveUsageBuckets(usageAggregator.takeCompleted())
        // 先关闭运行态门控：此后到达的定时器回调、事件回调、迟到 Task 一律
        // 不得写状态或 journal；随后才撤销各事件源与定时器。
        pendingEventReadTask?.cancel()
        pendingEventReadTask = nil
        // 复位合并窗口：若 stop 恰发生在 delay 窗口内，pendingSince 会永久滞留，
        // 之后的 start() 里所有事件都会被判 mergeIntoPending 而不再立即读取，
        // 事件驱动采样静默失效。此处按「已完成」记账清空 pending 状态。
        baseReadingCoalescer.fireCompleted(at: Date())
        dispatchTimer?.cancel()
        dispatchTimer = nil
        stopComponentPowerTimer()
        storageTimer?.invalidate()
        storageTimer = nil
        chargePolicyTimer?.invalidate()
        chargePolicyTimer = nil
        chargePolicyMonitor.stop()
        invalidateChargingObservationContinuity()
        sleepWatcher.stop()
        unregisterSystemEventSources()
        unregisterHealthHistoryObserver()
    }

    deinit {
        // 未配对 stop() 释放的兜底：source 与 context 持有的盒子已与实例解耦
        // （回调经弱引用安全返回），但 RunLoop source 会泄漏；调度到主队列
        // 完成最后一次配对清理，不引用实例自身。
        iopsSourceCleanup?.scheduleCleanupOnMain()
        if let observer = healthHistoryObserver {
            NotificationCenter.default.removeObserver(observer)
        }
    }

    // MARK: - 系统事件（IOPS / 低电量模式 / 热压力）

    /// 注册事件源：IOPS 电源变化用专用 RunLoop source；低电量模式与热压力用
    /// Foundation 系统通知。回调统一进入合并窗口后触发立即读取。
    private func registerSystemEventSources() {
        // IOPS 回调是 C 函数指针，不能捕获 Swift 上下文；通过 context 指针
        // 传回弱引用盒子。box 用 passRetained 交给 C context 持有：即使本实例
        // 未配对 stop() 就释放，盒子依然存活，回调经弱引用安全返回。
        // source 只挂在主 RunLoop 上，注销在主线程同步完成，
        // 回调内 assumeIsolated 安全且不会在 stop 后再触发。
        let box = WeakSamplerBox(self)
        let context = Unmanaged.passRetained(box).toOpaque()
        let callback: IOPowerSourceCallbackType = { rawContext in
            guard let rawContext else { return }
            let box = Unmanaged<WeakSamplerBox>.fromOpaque(rawContext).takeUnretainedValue()
            guard let sampler = box.sampler as? PowerSampler else { return }
            MainActor.assumeIsolated { sampler.handlePowerSourceEvent() }
        }
        if let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = source
            iopsSourceCleanup = IOPSSourceCleanup(source: source, context: context)
        } else {
            Unmanaged<WeakSamplerBox>.fromOpaque(context).release()
        }

        let center = NotificationCenter.default
        systemEventObservers.append(center.addObserver(
            forName: .NSProcessInfoPowerStateDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSystemEvent() }
        })
        systemEventObservers.append(center.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleSystemEvent() }
        })
    }

    private func unregisterSystemEventSources() {
        if let source = powerSourceRunLoopSource {
            CFRunLoopSourceInvalidate(source)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            powerSourceRunLoopSource = nil
        }
        // 配对释放 context 持有的盒子，防止泄漏；清理后回调（若仍到达）经
        // 弱引用空安全返回
        iopsSourceCleanup?.cleanupNow()
        iopsSourceCleanup = nil
        for observer in systemEventObservers {
            NotificationCenter.default.removeObserver(observer)
        }
        systemEventObservers.removeAll()
    }

    private func registerHealthHistoryObserver() {
        guard healthHistoryObserver == nil else { return }
        healthHistoryObserver = NotificationCenter.default.addObserver(
            forName: .batteryHealthHistoryDidChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.healthHistoryObserver != nil else { return }
                self.reloadHealthHistory()
            }
        }
    }

    private func unregisterHealthHistoryObserver() {
        if let observer = healthHistoryObserver {
            NotificationCenter.default.removeObserver(observer)
            healthHistoryObserver = nil
        }
    }

    private func reloadHealthHistory() {
        let updated = dataStore.healthHistory()
        if updated != healthHistory {
            healthHistory = updated
        }
    }

    /// 事件入口：合并窗口内的重复通知只产生一次读取。
    private func handleSystemEvent() {
        guard isStarted else { return }
        switch baseReadingCoalescer.eventReceived(now: Date()) {
        case .fireNow:
            sampleUI()
        case .delay(let delay):
            scheduleDelayedEventRead(after: delay)
        case .mergeIntoPending:
            break
        }
    }

    /// IOPS 电源变化也检查慢变策略；普通热状态/低电量模式通知不启动 pmset。
    private func handlePowerSourceEvent() {
        guard isStarted else { return }
        chargePolicyMonitor.refreshIfNeeded(force: true)
        handleSystemEvent()
    }

    private func scheduleDelayedEventRead(after delay: TimeInterval) {
        pendingEventReadTask?.cancel()
        pendingEventReadTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isStarted else { return }
            self.baseReadingCoalescer.fireCompleted(at: Date())
            self.sampleUI()
        }
    }

    // MARK: - 界面可见性

    /// 登记主窗口 / 菜单栏弹窗的可见性。任一界面打开即立即采样并切到前台节奏；
    /// 只有最后一个界面关闭后才回到后台低频，避免两个界面互相覆盖生命周期。
    func setReadingSurface(_ surface: LiveReadingSurface, visible: Bool) {
        let oldInterval = effectiveRefreshInterval
        guard liveReadingDemand.set(surface, visible: visible) else { return }

        let active = liveReadingDemand.hasVisibleSurface
        if active != isForegroundReadingActive {
            isForegroundReadingActive = active
        }
        if active {
            flushPendingBackgroundReadTimestamps()
        }
        let newInterval = effectiveRefreshInterval

        guard isStarted else { return }

        // 每次打开一个读数界面都先取一次，不必等待下一个 timer deadline。
        if visible {
            sampleUI()
            chargePolicyMonitor.refreshIfNeeded(force: true)
        }
        if oldInterval != newInterval {
            restartTimer(sampleImmediately: false)
        }
    }

    private var effectiveRefreshInterval: TimeInterval {
        SamplingCadence.effectiveInterval(hasVisibleSurface: liveReadingDemand.hasVisibleSurface)
    }

    /// 重启基础读数定时器。前台 5 秒、后台 15 秒；间隔是兜底读取尝试频率，
    /// 不代表电池驱动每轮都会发布新值（驱动可能数秒至十余秒才批量发布）。
    private func restartTimer(sampleImmediately: Bool = false) {
        dispatchTimer?.cancel()
        let interval = effectiveRefreshInterval
        if sampleImmediately { sampleUI() }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        let leewayMilliseconds = isForegroundReadingActive ? 500 : 2_000
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(leewayMilliseconds)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.sampleUI()
            }
        }
        timer.resume()
        dispatchTimer = timer
    }

    /// 高级分项采样独立于基础读数和界面可见性。用户主动开启后，Helper 与 App
    /// 均按 10 秒节奏产出/读取缓存，给每分钟历史点提供真实的新鲜分项样本；默认关闭。
    private func restartComponentPowerTimer(sampleImmediately: Bool) {
        stopComponentPowerTimer()
        guard isStarted, helperEnabled else { return }
        if sampleImmediately { sampleComponentPower() }

        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(
            deadline: .now() + SamplingCadence.componentPowerInterval,
            repeating: SamplingCadence.componentPowerInterval,
            leeway: .seconds(1)
        )
        timer.setEventHandler { [weak self] in
            Task { @MainActor [weak self] in
                self?.sampleComponentPower()
            }
        }
        timer.resume()
        componentPowerTimer = timer
    }

    private func stopComponentPowerTimer() {
        componentGeneration &+= 1
        componentTask?.cancel()
        componentTask = nil
        isComponentPowerSampleInFlight = false
        componentPowerTimer?.cancel()
        componentPowerTimer = nil
    }

    private func sampleComponentPower() {
        // 开关与生命周期双门控；关闭/未开启时绝不发起 XPC。
        guard ComponentReadingGate.shouldApply(
            helperEnabled: helperEnabled,
            lifecycleState: helperLifecycle.state,
            isStarted: isStarted
        ), !isComponentPowerSampleInFlight else { return }
        isComponentPowerSampleInFlight = true
        let generation = componentGeneration
        componentTask = Task { @MainActor [weak self] in
            defer {
                if let self, generation == self.componentGeneration {
                    self.isComponentPowerSampleInFlight = false
                }
            }
            guard let self else { return }
            do {
                let component = try await self.helperClient.readComponentPower()
                guard generation == self.componentGeneration, !Task.isCancelled,
                      ComponentReadingGate.shouldApply(helperEnabled: self.helperEnabled,
                                                       lifecycleState: self.helperLifecycle.state,
                                                       isStarted: self.isStarted) else { return }
                let age = Date().timeIntervalSince(component.receivedAt)
                guard age >= -2, age <= 30 else { self.clearComponentReadings(); return }
                if self.componentPowerError != nil { self.componentPowerError = nil }
                if self.lastComponentPowerAt != component.receivedAt { self.lastComponentPowerAt = component.receivedAt }
                let cpuAvail = component.cpu != nil
                let gpuAvail = component.gpu != nil
                let dramAvail = component.dram != nil
                let cpuVal = component.cpu ?? 0
                let gpuVal = component.gpu ?? 0
                let dramVal = component.dram ?? 0
                if self.cpuPowerAvailable != cpuAvail { self.cpuPowerAvailable = cpuAvail }
                if self.gpuPowerAvailable != gpuAvail { self.gpuPowerAvailable = gpuAvail }
                if self.dramPowerAvailable != dramAvail { self.dramPowerAvailable = dramAvail }
                if abs(self.cpuPower - cpuVal) > 0.05 || (cpuVal == 0 && self.cpuPower != 0) { self.cpuPower = cpuVal }
                if abs(self.gpuPower - gpuVal) > 0.05 || (gpuVal == 0 && self.gpuPower != 0) { self.gpuPower = gpuVal }
                if abs(self.dramPower - dramVal) > 0.05 || (dramVal == 0 && self.dramPower != 0) { self.dramPower = dramVal }
            } catch {
                guard generation == self.componentGeneration, !Task.isCancelled else { return }
                self.clearComponentReadings(clearError: false)
                if self.componentPowerError != error.localizedDescription {
                    self.componentPowerError = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Sleep / Wake

    private func handleSleep() {
        guard isStarted else { return }
        let now = Date()
        let monotonic = ProcessInfo.processInfo.systemUptime
        // 睡眠期间没有行为观测：不把睡前充电状态延伸到唤醒后的状态。
        invalidateChargingObservationContinuity(at: now)
        isSleeping = true
        areScreensSleeping = true
        usageAggregator.sleep(at: now, monotonicTime: monotonic)
        publishUsage(at: now, force: true)
        // 睡眠期间连续量立即截断，不得把睡前功率延伸进睡眠窗口
        aggregator.truncateContinuity(at: now, monotonicTime: monotonic)
        drainCompletedAggregatesIntoRecent()
    }

    private func handleScreensSleep() {
        guard isStarted else { return }
        areScreensSleeping = true
        let now = Date()
        usageScreenOn = false
        usageAggregator.changeScreen(on: false, at: now, monotonicTime: ProcessInfo.processInfo.systemUptime)
        publishUsage(at: now, force: true)
        if !isSleeping { sampleUI() }
    }

    private func handleScreensWake() {
        guard isStarted, !isSleeping else { return }
        areScreensSleeping = false
        let now = Date()
        usageScreenOn = true
        usageAggregator.changeScreen(on: true, at: now, monotonicTime: ProcessInfo.processInfo.systemUptime)
        publishUsage(at: now, force: true)
        sampleUI()
    }

    private func handleWake() {
        guard isStarted else { return }
        let now = Date()
        usageAggregator.wake(at: now, monotonicTime: ProcessInfo.processInfo.systemUptime)
        // 开盖唤醒时 screensDidWake 可能早于 didWake 到达（当时 isSleeping 仍为 true 被忽略），
        // 直接按主显示器硬件休眠状态同步：暗唤醒（Power Nap）下 CGDisplayIsAsleep 仍为非 0，
        // 不会误计为亮屏；正常亮屏唤醒下立即恢复 screenOn=true。
        let displayAwake = CGDisplayIsAsleep(CGMainDisplayID()) == 0
        usageScreenOn = displayAwake
        areScreensSleeping = !displayAwake
        publishUsage(at: now, force: true)
        isSleeping = false
        // 唤醒后立即重新读取，不等下一个兜底 deadline；系统健康也按 TTL 刷新
        if isStarted {
            sampleUI()
            chargePolicyMonitor.refreshIfNeeded(force: true)
            refreshSystemHealthInBackground()
        }
    }

    // MARK: - 基础读取

    private func sampleUI() {
        // stop 后到达的回调/迟到定时器一律不得写状态
        guard isStarted else { return }
        // IOPS 失败不伪造 0%/离电；旧百分比保留，实时遥测必须标记不可用。
        guard let reading = reader.readBatteryReading() else {
            handleBaseReadingFailure(at: Date())
            return
        }
        applyBaseReading(reading)
    }

    private func handleBaseReadingFailure(at date: Date) {
        let wasKnown = currentSourceKnown
        publishBaseTelemetry(nil, at: date)
        invalidateChargingObservationContinuity(at: date)
        usageAggregator.invalidate(at: date, monotonicTime: ProcessInfo.processInfo.systemUptime)
        publishUsage(at: date, force: true)
        if wasKnown != currentSourceKnown {
            NotificationCenter.default.post(name: .init("PowerSamplerDidUpdate"), object: nil)
        }
    }

    /// Publish only: no persistence, notifications, hardware access or integration.
    /// A failed read preserves the last level, but cannot keep old watts/temperature valid.
    func publishBaseTelemetry(_ reading: BatteryReader.BatteryReading?, at date: Date = Date()) {
        guard let reading else {
            if currentSourceKnown { currentSourceKnown = false }
            if currentPowerAvailable { currentPowerAvailable = false }
            if currentBatteryPowerAvailable { currentBatteryPowerAvailable = false }
            if currentAdapterInputAvailable { currentAdapterInputAvailable = false }
            if currentPowerIsEstimated { currentPowerIsEstimated = false }
            if currentVoltage != 0 { currentVoltage = 0 }
            if currentAmperage != 0 { currentAmperage = 0 }
            if currentTemperature != nil { currentTemperature = nil }
            var loadChanged = false
            if let updated = updatedMetric(loadMetric, value: nil, source: .unavailable, readAt: date) {
                loadMetric = updated
                loadChanged = true
            }
            var batChanged = false
            if let updated = updatedMetric(batteryPowerMetric, value: nil, source: .unavailable, readAt: date) {
                batteryPowerMetric = updated
                batChanged = true
            }
            var inputChanged = false
            if let updated = updatedMetric(inputPowerMetric, value: nil, source: .unavailable, readAt: date) {
                inputPowerMetric = updated
                inputChanged = true
            }
            var tempChanged = false
            if let updated = updatedMetric(temperatureMetric, value: nil, source: .unavailable, readAt: date) {
                temperatureMetric = updated
                tempChanged = true
            }
            if isForegroundReadingActive {
                latestBackgroundReadAt = nil
            } else if !(loadChanged && batChanged && inputChanged && tempChanged) {
                latestBackgroundReadAt = date
            }
            return
        }
        let ps = reading.powerSource
        let info = reading.batteryInfo
        let external = reading.resolvedExternalConnected
        let known = external != nil
        let isPluggedIn = external ?? currentExternalConnected
        var publishedSemanticChange = false
        if known != currentSourceKnown { currentSourceKnown = known; publishedSemanticChange = true }
        // 只在值真正变化时写 @Observable 属性：Observation 虽是属性级失效，
        // 无条件写仍会让读取该属性的视图逐 tick 重算。
        // 0.05W / 0.05°C 阈值滤掉遥测抖动；level/isCharging 等低频字段按相等门控。
        let wattage = reading.trustedSystemLoad ?? 0
        let batteryPower = info?.batteryPower ?? 0
        let adapterInputPower = info?.adapterInputPower ?? 0
        if ps.level != currentLevel { currentLevel = ps.level; publishedSemanticChange = true }
        if known && ps.isCharging != currentIsCharging { currentIsCharging = ps.isCharging; publishedSemanticChange = true }
        if isPluggedIn != currentExternalConnected { currentExternalConnected = isPluggedIn; publishedSemanticChange = true }
        if abs(wattage - currentWattage) > 0.05 || (wattage == 0 && currentWattage != 0) {
            currentWattage = wattage
            publishedSemanticChange = true
        }
        if abs(batteryPower - currentBatteryPower) > 0.05 || (batteryPower == 0 && currentBatteryPower != 0) {
            currentBatteryPower = batteryPower
            publishedSemanticChange = true
        }
        // 电池包功率可用性（含可信 0W）与系统负载可用性分开发布：
        // UI 三处（弹窗功率行 / 侧栏状态 / 功耗页电池行）据此决定显示数值
        // 还是「不可用」，不得把启动初值 0.0W 冒充真实读数。
        if (info?.batteryPowerAvailable ?? false) != currentBatteryPowerAvailable {
            currentBatteryPowerAvailable = info?.batteryPowerAvailable ?? false
            publishedSemanticChange = true
        }
        let powerAvailable = reading.trustedSystemLoad != nil
        if powerAvailable != currentPowerAvailable { currentPowerAvailable = powerAvailable; publishedSemanticChange = true }
        if (info?.systemPowerIsEstimated ?? false) != currentPowerIsEstimated {
            currentPowerIsEstimated = info?.systemPowerIsEstimated ?? false
            publishedSemanticChange = true
        }
        if (info?.voltage ?? 0) != currentVoltage { currentVoltage = info?.voltage ?? 0; publishedSemanticChange = true }
        if (info?.instantAmperage ?? 0) != currentAmperage { currentAmperage = info?.instantAmperage ?? 0; publishedSemanticChange = true }
        if abs(adapterInputPower - currentAdapterInputPower) > 0.05
            || (adapterInputPower == 0 && currentAdapterInputPower != 0)
        {
            currentAdapterInputPower = adapterInputPower
            publishedSemanticChange = true
        }
        let inputAvailable = external == true && info?.adapterInputPowerAvailable == true
        if inputAvailable != currentAdapterInputAvailable { currentAdapterInputAvailable = inputAvailable; publishedSemanticChange = true }
        let rawTemperature = info?.temperature ?? 0
        let resolvedTemperature: Double? = abs(rawTemperature) > 0.25 ? rawTemperature : nil
        switch (currentTemperature, resolvedTemperature) {
        case (nil, nil):
            break
        case let (old?, new?):
            if abs(new - old) >= 0.05 - 1e-9 {
                currentTemperature = new
                publishedSemanticChange = true
            }
        default:
            currentTemperature = resolvedTemperature
            publishedSemanticChange = true
        }
        let metricsChanged = updateQualityMetrics(reading)
        if isForegroundReadingActive || publishedSemanticChange || metricsChanged {
            if lastUpdateTime != reading.readAt {
                lastUpdateTime = reading.readAt
            }
            if isForegroundReadingActive {
                latestBackgroundSuccessAt = nil
                latestBackgroundReadAt = nil
            } else {
                latestBackgroundSuccessAt = nil
            }
        } else {
            latestBackgroundSuccessAt = reading.readAt
        }
    }

    /// 后台低频刷新系统健康度：启动一次、TTL 到期或唤醒后触发；
    /// system_profiler 在 detached 任务执行，绝不阻塞主线程、不进 5/15 秒路径。
    private func refreshSystemHealthInBackground() {
        guard BatteryHealthMetric.shouldRefresh(
            lastFetchAt: lastSystemHealthFetchAt, now: Date(), ttl: Self.systemHealthRefreshTTL
        ) else { return }
        lastSystemHealthFetchAt = Date()
        let reader = reader
        Task { @MainActor [weak self] in
            let reading = await Task.detached(priority: .utility) {
                reader.readSystemHealth()
            }.value
            guard let self, self.isStarted else { return }
            // 瞬时失败（spawn 失败/解析失败）不得降级既有口径：只有拿到新的
            // 系统读数才覆盖；失败时保留旧值（含启动时的回退口径），
            // TTL 到期后的下一次刷新自然重试，保持「系统值永远优先」口径一致。
            guard let reading else { return }
            self.applySystemHealth(reading)
        }
    }

    /// 应用后台 `system_profiler` 系统健康读数，并写入当日电池健康台账。
    func applySystemHealth(_ reading: SystemHealthReading) {
        let resolved = BatteryHealthMetric.resolved(
            systemReading: reading,
            maxCapacityMah: currentInfo?.maxCapacity ?? 0,
            designCapacityMah: currentInfo?.designCapacity ?? 0
        )
        if healthMetric != resolved { healthMetric = resolved }
        recordHealthTelemetry(at: reading.readAt)
    }

    /// 将当前已验证的电池硬件元数据与官方健康度写入永久本机日台账（零新增定时器，依赖既有事件驱动与防抖）。
    /// 跨日后若 `healthMetric.readAt` 仍属于前一日，绝不把昨日缓存健康度写入今日记录；
    /// 估算反推的满充容量同样不污染永久 mAh 趋势。
    func recordHealthTelemetry(info overrideInfo: BatteryInfo? = nil, at date: Date) {
        guard let info = overrideInfo ?? currentInfo, info.designCapacity > 0 else { return }
        let sameDaySystemHealth: (percent: Double, readAt: Date)? = if healthMetric.sourceIsSystem,
                                                                       healthMetric.percent > 0,
                                                                       let readAt = healthMetric.readAt,
                                                                       Calendar.current.isDate(readAt, inSameDayAs: date)
        {
            (healthMetric.percent, readAt)
        } else {
            nil
        }
        dataStore.recordHealthSample(
            date: date,
            systemHealthPercent: sameDaySystemHealth?.percent,
            systemHealthReadAt: sameDaySystemHealth?.readAt,
            fullChargeCapacityMah: (info.maxCapacity > 0 && !info.maxCapacityIsEstimated) ? info.maxCapacity : nil,
            nominalCapacityMah: info.nominalCapacity > 0 ? info.nominalCapacity : nil,
            designCapacityMah: info.designCapacity,
            cycleCount: info.cycleCount,
            designCycleCount: info.designCycleCount > 0 ? info.designCycleCount : nil,
            temperatureC: currentTemperature ?? temperatureMetric.value
        )
    }

    /// 回退口径：FullChargeCapacity÷DesignCapacity，标注「容量比估算」；
    /// 全部缺失时保持不可用（percent=0），不默认 100。
    private func applyFallbackHealth() {
        let fallback = BatteryHealthMetric.resolved(
            systemReading: nil,
            maxCapacityMah: currentInfo?.maxCapacity ?? 0,
            designCapacityMah: currentInfo?.designCapacity ?? 0
        )
        if healthMetric.percent != fallback.percent || healthMetric.sourceIsSystem != fallback.sourceIsSystem {
            healthMetric = fallback
        }
    }

    /// 应用一轮成功的基础读取：发布可观察状态、更新质量样本、喂入聚合器。
    private func applyBaseReading(_ reading: BatteryReader.BatteryReading) {
        let ps = reading.powerSource
        let info = reading.batteryInfo
        let readAt = reading.readAt
        let external = reading.resolvedExternalConnected
        let known = external != nil
        if known != currentSourceKnown || (known && (external != currentExternalConnected || ps.isCharging != currentIsCharging)) {
            estimateStateSince = readAt
        }
        if !known { invalidateChargingObservationContinuity(at: readAt) }
        let isPluggedIn = external ?? currentExternalConnected
        let previousLevel = currentLevel
        let previousCharging = currentIsCharging
        let previousExternalConnected = currentExternalConnected
        let previousSourceKnown = currentSourceKnown
        let behavior = known ? ChargingBehaviorObservation.resolve(
            isPluggedIn: isPluggedIn,
            isCharging: ps.isCharging,
            chargeStatus: info?.chargeStatus,
            observedAt: readAt
        ) : nil

        publishBaseTelemetry(reading)
        // 仅在行为状态、暂停原因或来源变更时发布，避免每 5 秒因 observedAt 递增触发 5 个视图无效重绘。
        let behaviorChanged = behavior?.state != currentChargingBehaviorObservation?.state
            || behavior?.reason != currentChargingBehaviorObservation?.reason
            || behavior?.source != currentChargingBehaviorObservation?.source
        if behaviorChanged {
            currentChargingBehaviorObservation = behavior
        }
        let processInfo = ProcessInfo.processInfo
        if processInfo.isLowPowerModeEnabled != currentLowPowerModeEnabled {
            currentLowPowerModeEnabled = processInfo.isLowPowerModeEnabled
        }
        let thermalState = Self.thermalStateLabel(processInfo.thermalState)
        if thermalState != currentThermalState { currentThermalState = thermalState }
        // currentInfo 只承载界面使用的元数据。电压、电流、温度和功率已有独立
        // 可观察字段；若把这些高频值也纳入 BatteryInfo 等值比较，会平白多触发
        // 一次读取该属性的视图更新。
        if shouldPublishMetadata(info) {
            currentInfo = info
            // 容量信息更新时，若系统健康值尚未取得，同步刷新容量比估算占位
            if !healthMetric.sourceIsSystem { applyFallbackHealth() }
        }
        // 检查策略快照在当前采样时刻的有效性；一旦超过 TTL 立即降级为 stale，
        // 防止过期目标继续渗透到完成证据、通知和充电估算中。
        // chargePolicyRevision 由 ChargePolicyMonitor 单一维护，短暂 stale 后刷新同目标不破坏长充电会话的完成证据。
        let effectivePolicy = chargePolicySnapshot.expiring(at: readAt, ttl: ChargePolicyMonitor.cacheTTL)
        if effectivePolicy != chargePolicySnapshot {
            chargePolicySnapshot = effectivePolicy
            recalculateEstimates()
        }
        if ChargePolicySnapshot.shouldRefresh(lastReadAt: chargePolicySnapshot.readAt, now: readAt, ttl: ChargePolicyMonitor.cacheTTL) {
            chargePolicyMonitor.refreshIfNeeded(now: readAt)
        }

        let completionEvidence = known ? chargeCompletionTracker.observe(
            pluggedIn: isPluggedIn,
            isCharging: ps.isCharging,
            level: ps.level,
            targetPercent: effectivePolicy.targetPercent,
            policyRevision: chargePolicyRevision
        ) : nil

        feedAggregator(reading)
        feedUsage(reading)
        recordHealthTelemetry(at: readAt)

        // IOPS 系统剩余时间作为独立证据保留（不透明值，不与 App 证据混算）
        lastSystemReportedMinutes = known ? ps.timeRemaining : -1

        // 状态栏与通知关心电量、充电态、接电态与来源可用性；相同数据不再每个轮询 tick 发通知。
        let statusChanged = previousLevel != currentLevel
            || previousCharging != currentIsCharging
            || previousExternalConnected != currentExternalConnected
            || previousSourceKnown != currentSourceKnown
        if statusChanged {
            NotificationCenter.default.post(name: .init("PowerSamplerDidUpdate"), object: nil)
            evaluateNotifications(
                level: currentLevel,
                externalConnected: external,
                isCharging: currentIsCharging,
                wasCharging: previousCharging,
                completionEvidence: completionEvidence
            )
        } else if external == false && !currentIsCharging && currentLevel <= 20 {
            // 启动时 NotificationManager 异步初始化完成或 30 分钟冷却到期后，即使整数电量尚未继续下降，也应评估低电量提醒。
            evaluateLowBatteryNotificationOnly(
                level: currentLevel,
                externalConnected: external,
                isCharging: currentIsCharging
            )
        }

        // 电源状态切换（插拔/充放转换）是估算的合法重算触发
        if isPluggedIn != previousExternalConnected || previousCharging != currentIsCharging {
            recalculateEstimates()
        } else if Date().timeIntervalSince(lastEstimateRecalcAt) >= Self.estimateRecalcInterval {
            // 兜底重算节奏：最多每 30 秒一次，绝不扫描全量历史
            recalculateEstimates()
        }
    }

    private func evaluateLowBatteryNotificationOnly(
        level: Double,
        externalConnected: Bool?,
        isCharging: Bool
    ) {
        let notifier = NotificationManager.shared
        let now = Date()
        if NotificationPolicy.shouldSendLowBattery(
            level: level,
            externalConnected: externalConnected,
            isCharging: isCharging,
            lowBatteryEnabled: notifier.lowBatteryEnabled,
            permissionValid: notifier.permissionValid,
            lastNotificationAt: notifier.lastLowBatteryNotificationAt,
            now: now
        ) {
            notifier.sendLowBattery(level: level)
        }
    }

    /// 通知策略接线：触发门槛与冷却窗口由纯策略裁决；
    /// 开关与授权状态来自 NotificationManager（持久化），启动/读取电量从不请求权限。
    private func evaluateNotifications(
        level: Double,
        externalConnected: Bool?,
        isCharging: Bool,
        wasCharging: Bool,
        completionEvidence: ChargeCompletionEvidence?
    ) {
        let notifier = NotificationManager.shared
        let now = Date()
        if NotificationPolicy.shouldSendLowBattery(
            level: level,
            externalConnected: externalConnected,
            isCharging: isCharging,
            lowBatteryEnabled: notifier.lowBatteryEnabled,
            permissionValid: notifier.permissionValid,
            lastNotificationAt: notifier.lastLowBatteryNotificationAt,
            now: now
        ) {
            notifier.sendLowBattery(level: level)
        }
        let effectivePolicy = chargePolicySnapshot.expiring(at: now, ttl: ChargePolicyMonitor.cacheTTL)
        if effectivePolicy != chargePolicySnapshot {
            chargePolicySnapshot = effectivePolicy
            recalculateEstimates()
        }
        if let targetPercent = effectivePolicy.targetPercent,
           NotificationPolicy.shouldSendFullCharge(
            level: level,
            externalConnected: externalConnected,
            wasCharging: wasCharging,
            isCharging: isCharging,
            targetPercent: targetPercent,
            completionEvidence: completionEvidence,
            policyRevision: chargePolicyRevision,
            fullChargeEnabled: notifier.fullChargeEnabled,
            permissionValid: notifier.permissionValid,
            lastNotificationAt: notifier.lastFullChargeNotificationAt,
            now: now
        ) {
            notifier.sendChargeTargetReached(level: level, targetPercent: targetPercent)
        }
    }

    /// 更新数据质量样本。语义字段变化时始终发布；后台静默期若仅 `readAt` 推进则暂存，待前台可见时统一回写。
    /// 注意：先值拷贝再按需赋回 `@Observable` 属性，避免 `inout` 触发 `_modify` 无条件发出 Observation 失效通知。
    @discardableResult
    private func updateQualityMetrics(_ reading: BatteryReader.BatteryReading) -> Bool {
        let info = reading.batteryInfo
        let provenance = reading.provenance
        let readAt = reading.readAt
        let inputAvailable = reading.resolvedExternalConnected == true
            && info?.adapterInputPowerAvailable == true
        var inputChanged = false
        if let updated = updatedMetric(
            inputPowerMetric,
            value: inputAvailable ? info?.adapterInputPower : nil,
            source: inputAvailable ? .telemetrySystemInput : .unavailable,
            readAt: readAt
        ) {
            inputPowerMetric = updated
            inputChanged = true
        }

        var loadChanged = false
        if let updated = updatedMetric(
            loadMetric,
            value: reading.trustedSystemLoad,
            source: provenance.systemLoadSource == .unavailable && reading.trustedSystemLoad == nil
                ? .unavailable : provenance.systemLoadSource,
            isEstimated: provenance.systemLoadIsEstimated,
            readAt: readAt
        ) {
            loadMetric = updated
            loadChanged = true
        }
        let batteryPowerAvailable = info?.batteryPowerAvailable ?? false
        let batteryPowerValue = info?.batteryPower ?? 0
        // 可信零瓦 = available + some(0)；没读到功率 = unavailable + nil。
        // 兼容哨兵 0（available=false 时的 batteryPower==0）不得进入质量模型。
        var batteryChanged = false
        if let updated = updatedMetric(
            batteryPowerMetric,
            value: batteryPowerAvailable ? .some(batteryPowerValue) : .none,
            source: batteryPowerAvailable ? provenance.batteryPowerSource : .unavailable,
            isEstimated: provenance.batteryPowerSource == .voltageCurrentDerived,
            readAt: readAt
        ) {
            batteryPowerMetric = updated
            batteryChanged = true
        }
        let temperature = info?.temperature ?? 0
        // 合法负温度（冬季户外）必须计入覆盖；0 兼任「不可读」哨兵。
        var tempChanged = false
        if let updated = updatedMetric(
            temperatureMetric,
            value: abs(temperature) > 0.25 ? temperature : nil,
            source: provenance.temperatureSource ?? .unavailable,
            readAt: readAt
        ) {
            temperatureMetric = updated
            tempChanged = true
        }
        let allUpdated = inputChanged && loadChanged && batteryChanged && tempChanged
        if !isForegroundReadingActive && !allUpdated {
            latestBackgroundReadAt = readAt
        }
        return inputChanged || loadChanged || batteryChanged || tempChanged
    }

    private func updatedMetric<Value: Equatable>(
        _ metric: TelemetrySample<Value>,
        value newValue: Value?,
        source: TelemetrySource,
        isEstimated: Bool = false,
        readAt: Date,
        sourceSampleAt: Date? = nil
    ) -> TelemetrySample<Value>? {
        let newAvailability: TelemetryAvailability = newValue == nil ? .unavailable : .available
        let normalizedSampleAt = source == .powermetrics ? sourceSampleAt : nil
        let semanticChanged = metric.value != newValue
            || metric.availability != newAvailability
            || metric.source != source
            || metric.isEstimated != isEstimated
            || metric.sourceSampleAt != normalizedSampleAt
        guard semanticChanged || isForegroundReadingActive else { return nil }
        var copy = metric
        copy.observe(
            newValue,
            source: source,
            isEstimated: isEstimated,
            readAt: readAt,
            sourceSampleAt: sourceSampleAt
        )
        return copy
    }

    private func flushPendingBackgroundReadTimestamps() {
        if let pendingSuccess = latestBackgroundSuccessAt {
            latestBackgroundSuccessAt = nil
            if lastUpdateTime < pendingSuccess {
                lastUpdateTime = pendingSuccess
            }
        }
        if let pendingReadAt = latestBackgroundReadAt {
            latestBackgroundReadAt = nil
            if loadMetric.readAt < pendingReadAt { loadMetric.readAt = pendingReadAt }
            if batteryPowerMetric.readAt < pendingReadAt { batteryPowerMetric.readAt = pendingReadAt }
            if inputPowerMetric.readAt < pendingReadAt { inputPowerMetric.readAt = pendingReadAt }
            if temperatureMetric.readAt < pendingReadAt { temperatureMetric.readAt = pendingReadAt }
        }
    }

    /// 把本轮可信连续量观测喂入分钟聚合器。
    private func feedAggregator(_ reading: BatteryReader.BatteryReading) {
        let info = reading.batteryInfo
        let readAt = reading.readAt
        let temperature = info?.temperature ?? 0
        aggregator.observe(WindowTelemetryAggregator.Observation(
            date: readAt,
            trustedSystemLoad: reading.trustedSystemLoad,
            batteryChannel: reading.batteryChannel,
            // 合法负温度（冬季户外）必须计入温度覆盖与趋势；0 = 不可读哨兵
            temperatureCelsius: abs(temperature) > 0.25 ? temperature : nil,
            expectedInterval: effectiveRefreshInterval,
            monotonicTime: ProcessInfo.processInfo.systemUptime
        ))
    }

    /// Fresh local usage only: no ChargeCycle input, no SOC-drop threshold.
    private func feedUsage(_ reading: BatteryReader.BatteryReading) {
        guard !isSleeping else { return }
        let ps = reading.powerSource
        let external = reading.resolvedExternalConnected
        var dischargePower: Double?
        if case .discharge(let watts) = reading.batteryChannel { dischargePower = watts }
        let changed = external != lastUsageExternal
        usageAggregator.observe(.init(
            date: reading.readAt,
            externalConnected: external,
            screenOn: usageScreenOn,
            level: ps.level,
            dischargePower: dischargePower,
            powerIsEstimated: reading.provenance.batteryPowerSource == .voltageCurrentDerived,
            expectedInterval: effectiveRefreshInterval,
            timeZone: TimeZone(identifier: TimeZone.autoupdatingCurrent.identifier) ?? .current,
            monotonicTime: ProcessInfo.processInfo.systemUptime
        ))
        lastUsageExternal = external
        publishUsage(at: reading.readAt, force: changed)
    }

    private func publishUsage(at date: Date, force: Bool) {
        let buckets = usageAggregator.takeCompleted()
        dataStore.saveUsageBuckets(buckets)
        let minute = Int(date.timeIntervalSince1970 / 60)
        if minute != lastUsagePublishMinute || force {
            lastUsagePublishMinute = minute
            if buckets.isEmpty {
                NotificationCenter.default.post(name: .batteryUsageDidChange, object: nil)
            }
        }
    }

    func liveUsageBuckets(at date: Date = Date()) -> [UsageBucket] {
        usageAggregator.preview(at: date)
    }

    /// 估算器重算：输入有界（最近 120 快照 + 最近 120 分钟聚合），
    /// 只在新分钟快照、电源状态切换或最多每 30 秒触发。
    private func recalculateEstimates() {
        lastEstimateRecalcAt = Date()
        var input = RuntimeEstimator.Inputs()
        input.now = Date()
        input.currentLevel = currentLevel
        input.isCharging = currentIsCharging
        input.externalConnected = currentSourceKnown ? currentExternalConnected : nil
        input.stateObservedSince = estimateStateSince
        input.snapshots = dataStore.localSnapshots(limit: 120)
        input.minuteAggregates = recentAggregates
        input.fullChargeCapacityMah = currentInfo?.maxCapacity ?? 0
        input.fullChargeCapacityIsEstimated = currentInfo?.maxCapacityIsEstimated ?? false
        input.voltageMV = currentVoltage
        input.systemReportedMinutes = lastSystemReportedMinutes
        let effectivePolicy = chargePolicySnapshot.expiring(at: input.now, ttl: ChargePolicyMonitor.cacheTTL)
        if effectivePolicy != chargePolicySnapshot {
            chargePolicySnapshot = effectivePolicy
        }
        input.chargeTargetPercent = effectivePolicy.chargingEstimateTargetPercent.map(Double.init)
        input.liveChargeWatts = (currentSourceKnown && currentExternalConnected && currentIsCharging && currentBatteryPowerAvailable && currentBatteryPower > 0)
            ? currentBatteryPower
            : nil

        let nextDischarge = RuntimeEstimator.dischargeEstimate(input)
        let nextCharge = RuntimeEstimator.chargeEstimate(input)
        let nextSystem = RuntimeEstimator.systemReportedEstimate(input)
        let nextSystemCharge = RuntimeEstimator.systemReportedChargeEstimate(input)
        if dischargeEstimate != nextDischarge { dischargeEstimate = nextDischarge }
        if chargeEstimate != nextCharge { chargeEstimate = nextCharge }
        if systemReportedEstimate != nextSystem { systemReportedEstimate = nextSystem }
        if systemReportedChargeEstimate != nextSystemCharge { systemReportedChargeEstimate = nextSystemCharge }
    }

    @objc private func fireStorage() {
        guard isStarted else { return }
        sampleStorage()
    }

    @objc private func fireChargePolicyRefresh() {
        guard isStarted else { return }
        chargePolicyMonitor.refreshIfNeeded()
    }

    /// 读取缺口或睡眠会打断可证明的连续观察。
    private func invalidateChargingObservationContinuity(at date: Date = Date()) {
        estimateStateSince = date
        if dischargeEstimate != nil { dischargeEstimate = nil }
        if chargeEstimate != nil { chargeEstimate = nil }
        if systemReportedEstimate != nil { systemReportedEstimate = nil }
        if systemReportedChargeEstimate != nil { systemReportedChargeEstimate = nil }
        aggregator.truncateContinuity(at: estimateStateSince, monotonicTime: ProcessInfo.processInfo.systemUptime)
        if currentChargingBehaviorObservation != nil { currentChargingBehaviorObservation = nil }
        chargeCompletionTracker.reset()
    }

    private func shouldPublishMetadata(_ info: BatteryInfo?) -> Bool {
        guard let info else { return currentInfo != nil }
        guard let currentInfo else { return true }
        return info.designCapacity != currentInfo.designCapacity
            || info.maxCapacity != currentInfo.maxCapacity
            || info.maxCapacityIsEstimated != currentInfo.maxCapacityIsEstimated
            || info.nominalCapacity != currentInfo.nominalCapacity
            || info.cycleCount != currentInfo.cycleCount
            || info.designCycleCount != currentInfo.designCycleCount
            || info.isCharging != currentInfo.isCharging
            || info.externalConnected != currentInfo.externalConnected
            || info.chargeStatus != currentInfo.chargeStatus
            || info.adapterWatts != currentInfo.adapterWatts
            || info.adapterProtocol != currentInfo.adapterProtocol
    }

    private func sampleStorage() {
        // stop 后到达的定时器回调一律不得写 journal 或状态
        guard isStarted else { return }
        // 采集失败时跳过这一分钟；伪造 0% 快照比一个明确的数据缺口更有害。
        guard let reading = reader.readBatteryReading() else {
            handleBaseReadingFailure(at: Date())
            return
        }
        applyBaseReading(reading)
        let ps = reading.powerSource
        let info = reading.batteryInfo
        let isPluggedIn = reading.resolvedExternalConnected

        var snapshot = BatterySnapshot(
            timestamp: reading.readAt,
            level: ps.level,
            isCharging: ps.isCharging,
            wattage: reading.trustedSystemLoad ?? 0,
            systemPowerAvailable: reading.trustedSystemLoad != nil,
            systemPowerIsEstimated: info?.systemPowerIsEstimated ?? false,
            externalConnected: isPluggedIn
        )
        let completedMinutes = aggregator.takeCompletedAggregates()
        // 若定时抖动跨越了多个完整分钟，先把先前错过的完整分钟也独立落盘并入估算缓冲，避免静默丢点。
        if completedMinutes.count > 1 {
            for earlier in completedMinutes.dropLast() {
                var backfilled = BatterySnapshot(
                    timestamp: earlier.windowStart.addingTimeInterval(WindowTelemetryAggregator.windowLength),
                    level: ps.level,
                    isCharging: ps.isCharging,
                    wattage: earlier.systemPowerAverage ?? 0,
                    systemPowerAvailable: earlier.systemPowerAverage != nil,
                    systemPowerIsEstimated: false,
                    externalConnected: isPluggedIn
                )
                backfilled.apply(minuteAggregate: earlier)
                dataStore.saveSnapshot(backfilled)
            }
        }
        if let aggregate = completedMinutes.last {
            snapshot.apply(minuteAggregate: aggregate)
        }
        if !completedMinutes.isEmpty {
            appendRecentAggregates(completedMinutes)
        }
        dataStore.saveSnapshot(snapshot)

        // 新分钟快照是估算的合法重算触发
        recalculateEstimates()

        // 系统健康的小时级 TTL 刷新：仅一次廉价日期比较，读取在后台执行，
        // 绝不随 5/15 秒基础采样重复启动 system_profiler。
        refreshSystemHealthInBackground()
    }

    func openBatterySettings() {
        reader.openBatterySettings()
    }

    private static func thermalStateLabel(_ state: ProcessInfo.ThermalState) -> String {
        switch state {
        case .nominal: "正常"
        case .fair: "偏高"
        case .serious: "较高"
        case .critical: "严重"
        @unknown default: "未知"
        }
    }

    /// 用户开启/关闭「高级采样」。
    ///
    /// 开启：检查 Helper 状态，必要时安装/更新（osascript 弹一次管理员密码框在
    /// 后台线程执行）；成功后启动 CPU/GPU/内存分项采样。安装失败或用户取消管理员
    /// 授权时恢复真实关闭状态并保留错误原因（UI 提供重试入口），绝不假装已开启。
    /// 关闭：只停止分项定时器与后续 XPC、持久化关闭、清空分项读数；
    /// 绝不调用 uninstallHelper、绝不请求管理员密码。
    func setAdvancedSamplingEnabled(_ enabled: Bool) async {
        if enabled {
            guard !helperLifecycle.isBusy else { return }
            let ok = await helperLifecycle.beginEnable()
            if ok {
                persistAdvancedSamplingEnabled(true)
                helperEnabled = true
                if isStarted {
                    restartComponentPowerTimer(sampleImmediately: true)
                }
            } else {
                // 安装失败/授权取消/XPC 错误：恢复真实关闭状态
                persistAdvancedSamplingEnabled(false)
                helperEnabled = false
                stopComponentPowerTimer()
                clearComponentReadings()
            }
        } else {
            // 只停止采样：立即停定时器、持久化关闭、清空分项读数
            persistAdvancedSamplingEnabled(false)
            helperEnabled = false
            helperLifecycle.setDisabled()
            stopComponentPowerTimer()
            clearComponentReadings()
        }
    }

    /// 唯一显式卸载入口（设置页「采样诊断 → 移除辅助服务…」二次确认后调用）。
    /// 先停止采样并清零，再请求管理员授权移除 root 守护进程；卸载失败/取消时
    /// 由 lifecycle 记录 error，采样保持关闭。
    func removeHelperService() async {
        guard !helperLifecycle.isBusy else { return }
        persistAdvancedSamplingEnabled(false)
        helperEnabled = false
        stopComponentPowerTimer()
        clearComponentReadings()
        _ = await helperLifecycle.remove()
    }

    private func persistAdvancedSamplingEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.helperEnabledKey)
    }

    private func drainCompletedAggregatesIntoRecent() {
        let finished = aggregator.takeCompletedAggregates()
        guard !finished.isEmpty else { return }
        appendRecentAggregates(finished)
    }

    private func appendRecentAggregates(_ items: [MinuteAggregate]) {
        recentAggregates.append(contentsOf: items)
        if recentAggregates.count > Self.recentAggregatesLimit {
            recentAggregates.removeFirst(recentAggregates.count - Self.recentAggregatesLimit)
        }
    }

    /// 清空分项读数并标记不可用：关闭高级采样后不得继续展示旧样本。
    private func clearComponentReadings(clearError: Bool = true) {
        if cpuPowerAvailable { cpuPowerAvailable = false }
        if gpuPowerAvailable { gpuPowerAvailable = false }
        if dramPowerAvailable { dramPowerAvailable = false }
        if clearError, componentPowerError != nil { componentPowerError = nil }
        if cpuPower != 0 { cpuPower = 0 }
        if gpuPower != 0 { gpuPower = 0 }
        if dramPower != 0 { dramPower = 0 }
        if lastComponentPowerAt != .distantPast { lastComponentPowerAt = .distantPast }
    }

    /// IOPS C 回调与 MainActor 采样器之间的弱引用桥。
    /// 盒子由 CFRunLoopSource 的 context 以 passRetained 持有：注册时创建，
    /// 注销（或 deinit 兜底清理）时 release。即使采样器未配对 stop() 释放，
    /// 回调经弱引用取不到 sampler 时安全返回，不存在悬挂指针。
    private final class WeakSamplerBox {
        weak var sampler: AnyObject?
        init(_ sampler: AnyObject) { self.sampler = sampler }
    }

    /// IOPS RunLoop source 与 C context 的配对清理器。
    /// @unchecked Sendable：仅携带不可变指针；清理动作固定在主队列执行
    /// （与注册线程一致，CFRunLoopSource 要求在安装它的 RunLoop 线程注销）。
    private final class IOPSSourceCleanup: @unchecked Sendable {
        private let source: CFRunLoopSource
        private let context: UnsafeMutableRawPointer

        init(source: CFRunLoopSource, context: UnsafeMutableRawPointer) {
            self.source = source
            self.context = context
        }

        /// 主线程同步清理（stop() 的正常路径）
        func cleanupNow() {
            CFRunLoopSourceInvalidate(source)
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
            Unmanaged<WeakSamplerBox>.fromOpaque(context).release()
        }

        /// deinit 兜底路径：主队列异步清理，不引用已释放的采样器实例
        func scheduleCleanupOnMain() {
            DispatchQueue.main.async { self.cleanupNow() }
        }
    }
}
