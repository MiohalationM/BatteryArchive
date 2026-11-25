import Foundation
import Testing
@testable import BatteryArchive

private final class ControllableClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { self.current = date }

    func now() -> Date {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    func advance(by seconds: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        current = current.addingTimeInterval(seconds)
    }

    func set(_ date: Date) {
        lock.lock()
        defer { lock.unlock() }
        current = date
    }
}

private final class ControllablePolicyRunner: ChargePolicyCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var target = 80
    private var noActiveLimit = false
    private var reads = 0
    private var delaySeconds: TimeInterval = 0
    private var shouldFail = false
    private var nextReadGate: DispatchSemaphore?
    private var readEntered = DispatchSemaphore(value: 0)

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func setTarget(_ target: Int) {
        lock.lock()
        defer { lock.unlock() }
        self.target = target
        self.noActiveLimit = false
    }

    func setNoActiveLimit(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.noActiveLimit = enabled
    }

    func setDelay(_ delay: TimeInterval) {
        lock.lock()
        defer { lock.unlock() }
        self.delaySeconds = delay
    }

    func setFail(_ fail: Bool) {
        lock.lock()
        defer { lock.unlock() }
        self.shouldFail = fail
    }

    /// 阻塞下一次 read()，直到测试显式释放，消除重负载下基于固定 sleep 的竞态。
    func holdNextRead() -> DispatchSemaphore {
        let gate = DispatchSemaphore(value: 0)
        lock.lock()
        nextReadGate = gate
        lock.unlock()
        return gate
    }

    func read() -> ChargePolicyCommandResult {
        lock.lock()
        reads += 1
        let delay = delaySeconds
        let fail = shouldFail
        let currentTarget = target
        let isNoLimit = noActiveLimit
        let gate = nextReadGate
        nextReadGate = nil
        lock.unlock()
        readEntered.signal()

        if let gate {
            _ = gate.wait(timeout: .now() + 5)
        } else if delay > 0 {
            Thread.sleep(forTimeInterval: delay)
        }
        if fail {
            return .init(stdout: nil, exitCode: 1)
        }
        if isNoLimit {
            return .init(stdout: "No battery level limits set\n", exitCode: 0)
        }
        return .init(stdout: """
        Battery level limits:
        (
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = \(currentTarget); }
        )
        """, exitCode: 0)
    }
}

private final class DelayedChargePolicyRunner: ChargePolicyCommandRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var reads = 0

    var readCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return reads
    }

    func read() -> ChargePolicyCommandResult {
        lock.lock()
        reads += 1
        lock.unlock()
        Thread.sleep(forTimeInterval: 0.05)
        return ChargePolicyCommandResult(stdout: """
        Battery level limits:
        (
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 80; }
        )
        """, exitCode: 0)
    }
}

@Suite struct ChargePolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    /// Wait for the actual callback, rather than assuming detached work finishes
    /// within 30ms while the entire test suite is using the executor.
    @MainActor private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    /// 实机样例：只读 `/usr/bin/pmset -g battlimit` 的输出夹具。
    /// `chargeSocLimitOwner` 值分别独立脱敏；两个重复的 manualChargeLimit / 80 策略保留。
    private let liveDuplicateFixture = """
    Battery level limits:
    (
            {
                Terminated = 0;
                chargeSocLimitDrain = 1;
                chargeSocLimitIsEOC = 1;
                chargeSocLimitNoChargeToFull = 0;
                chargeSocLimitOwner = <redacted-owner-a>;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 80;
            },
            {
                Terminated = 0;
                chargeSocLimitDrain = 1;
                chargeSocLimitIsEOC = 1;
                chargeSocLimitNoChargeToFull = 0;
                chargeSocLimitOwner = <redacted-owner-b>;
                chargeSocLimitReason = manualChargeLimit;
                chargeSocLimitSoc = 80;
            }
    )
    """

    private func parse(_ output: String, exitCode: Int32? = 0) -> ChargePolicySnapshot {
        ChargePolicyParser.parse(.init(stdout: output, exitCode: exitCode), readAt: now)
    }

    private func onePolicy(terminated: Int = 0, reason: String = "manualChargeLimit", target: Int = 80) -> String {
        """
        Battery level limits:
        (
            {
                Terminated = \(terminated);
                chargeSocLimitReason = \(reason);
                chargeSocLimitSoc = \(target);
            }
        )
        """
    }

    @Test("实机重复策略去重，并保留来源与读取时间")
    func parsesSanitizedLiveDuplicateOutput() {
        let snapshot = parse(liveDuplicateFixture)
        #expect(snapshot.status == .configured)
        #expect(snapshot.targetPercent == 80)
        #expect(snapshot.source == ChargePolicySnapshot.sourceName)
        #expect(snapshot.readAt == now)
    }

    @Test("支持80、85、90、95和100五档")
    func supportsFiveSystemTargets() {
        for target in ChargeLimitTarget.allCases {
            let fixture = liveDuplicateFixture.replacingOccurrences(
                of: "chargeSocLimitSoc = 80;",
                with: "chargeSocLimitSoc = \(target.rawValue);"
            )
            let snapshot = parse(fixture)
            #expect(snapshot.status == .configured)
            #expect(snapshot.targetPercent == target.rawValue)
        }
    }

    @Test("已终止策略不成为目标")
    func ignoresTerminatedStrategies() {
        let active = parse(onePolicy(terminated: 0, target: 85))
        let terminated = parse(onePolicy(terminated: 1, target: 80))
        #expect(active.targetPercent == 85)
        #expect(terminated.status == .noActiveLimit)
        #expect(terminated.targetPercent == nil)
    }

    @Test("未知策略不成为目标")
    func rejectsUnknownReasonAndUnsupportedTier() {
        let unknownReason = parse(onePolicy(reason: "futurePolicy", target: 80))
        let unsupportedTier = parse(onePolicy(target: 75))
        let unknownTermination = parse(onePolicy().replacingOccurrences(of: "Terminated = 0", with: "Terminated = maybe"))
        #expect(unknownReason.status == .unknownPolicy)
        #expect(unknownReason.targetPercent == nil)
        #expect(unsupportedTier.status == .unknownPolicy)
        #expect(unsupportedTier.targetPercent == nil)
        #expect(unknownTermination.targetPercent == nil)
    }

    @Test("多个活动策略目标冲突时不挑选其中一个")
    func conflictingActiveTargetsRemainUnknown() {
        let conflict = """
        Battery level limits:
        (
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 80; },
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 85; }
        )
        """
        #expect(parse(conflict).status == .conflictingPolicies)
        #expect(parse(conflict).targetPercent == nil)
    }

    @Test("读取失败或格式变化如实降级")
    func failedOrChangedOutputIsUnavailableOrUnknown() {
        #expect(parse(liveDuplicateFixture, exitCode: 1).status == .unavailable)
        #expect(parse("Battery level limits: <new format>").status == .unknownPolicy)
        #expect(parse(liveDuplicateFixture + "\nUnexpected suffix").status == .unknownPolicy)
        #expect(parse(onePolicy().replacingOccurrences(of: "Terminated = 0;", with: "malformed; Terminated = 0;"))
            .status == .unknownPolicy)
        #expect(parse("Battery level limits:\n(\n)\n").status == .noActiveLimit)
        let noLimitsSet = parse("No battery level limits set\n")
        #expect(noLimitsSet.status == .noActiveLimit)
        #expect(noLimitsSet.targetPercent == nil)
        #expect(noLimitsSet.statusLabel == "未设置")
        #expect(parse("pmset failed").targetPercent == nil)
    }

    @Test @MainActor func concurrentRefreshRequestsDoNotOverlapReads() async {
        let runner = DelayedChargePolicyRunner()
        let monitor = ChargePolicyMonitor(runner: runner)
        let now = Date()
        monitor.refreshIfNeeded(now: now)
        monitor.refreshIfNeeded(force: true, now: now.addingTimeInterval(60))

        await waitUntil { monitor.snapshot.targetPercent == 80 }
        #expect(runner.readCount == 1)
        #expect(monitor.snapshot.targetPercent == 80)
    }

    @Test("读取超过TTL后目标失效，不能继续进入估算或通知")
    func expiresPolicySnapshot() {
        let fresh = parse(onePolicy())
        #expect(fresh.expiring(at: now.addingTimeInterval(899), ttl: 900).targetPercent == 80)
        let expired = fresh.expiring(at: now.addingTimeInterval(900), ttl: 900)
        #expect(expired.status == .stale)
        #expect(expired.targetPercent == nil)
        #expect(ChargePolicySnapshot.shouldRefresh(lastReadAt: now, now: now.addingTimeInterval(899), ttl: 900) == false)
        #expect(ChargePolicySnapshot.shouldRefresh(lastReadAt: now, now: now.addingTimeInterval(900), ttl: 900))
        #expect(ChargePolicySnapshot.shouldRefresh(lastReadAt: nil, now: now, ttl: 900))
    }

    @Test("限流期间强制刷新需求合并并在允许后补读")
    @MainActor func coalescesForcedRefreshesUnderRateLimit() async {
        let clock = ControllableClock(now)
        let runner = ControllablePolicyRunner()
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        // 首次读取：80%
        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { monitor.snapshot.targetPercent == 80 }
        #expect(runner.readCount == 1)
        #expect(monitor.snapshot.targetPercent == 80)

        // 5秒后外部上限变更为 85%，触发强制刷新（处于30秒限流内）
        clock.advance(by: 5)
        runner.setTarget(85)
        monitor.refreshIfNeeded(force: true, now: clock.now())
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(runner.readCount == 1) // 被限流，暂不发起进程

        // 10秒后再次到达强制事件，合并需求，不增加进程
        clock.advance(by: 5)
        monitor.refreshIfNeeded(force: true, now: clock.now())
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(runner.readCount == 1)

        // 31秒（距首次尝试已满30秒），普通周期检查触发补读
        clock.set(now.addingTimeInterval(31))
        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { monitor.snapshot.targetPercent == 85 }
        #expect(runner.readCount == 2)
        #expect(monitor.snapshot.targetPercent == 85)
    }

    @Test("读取进行中到达的新请求不丢失并在完成后执行")
    @MainActor func requestsDuringInFlightReadArePreserved() async {
        let clock = ControllableClock(now)
        let runner = ControllablePolicyRunner()
        let firstGate = runner.holdNextRead()
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        monitor.refreshIfNeeded(now: clock.now())
        // 等待进入 in-flight
        await waitUntil { runner.readCount == 1 }

        // 在读取期间发生目标变更并请求强制刷新
        runner.setTarget(90)
        clock.advance(by: 35) // 时间已过限流窗口
        monitor.refreshIfNeeded(force: true, now: clock.now())
        firstGate.signal()

        // 等待首次读取及随后补发读取完成
        await waitUntil { runner.readCount == 2 && monitor.snapshot.targetPercent == 90 }
        #expect(runner.readCount == 2)
        #expect(monitor.snapshot.targetPercent == 90)
    }

    @Test("首次定时器略早于TTL跳过读取，精确到期时目标失效且阻断估算与提醒")
    @MainActor func timerBeforeTTLSkippedAndExactExpirationStopsConsumers() async {
        let clock = ControllableClock(now)
        let runner = ControllablePolicyRunner()
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { monitor.snapshot.targetPercent == 80 }
        #expect(runner.readCount == 1)
        #expect(monitor.snapshot.targetPercent == 80)

        // 定时器触发在 TTL - 0.01 秒（899.99秒）
        clock.set(now.addingTimeInterval(ChargePolicyMonitor.cacheTTL - 0.01))
        monitor.refreshIfNeeded(now: clock.now())
        try? await Task.sleep(nanoseconds: 20_000_000)
        #expect(runner.readCount == 1) // 未到 TTL，跳过读取
        #expect(monitor.snapshot.targetPercent == 80)

        // 时间步进到精确到期时刻（900秒）
        clock.set(now.addingTimeInterval(ChargePolicyMonitor.cacheTTL))
        let expiredSnapshot = monitor.snapshot
        #expect(expiredSnapshot.status == .stale)
        #expect(expiredSnapshot.targetPercent == nil)
        #expect(expiredSnapshot.statusLabel == "读取已过期")

        // 验证过期目标不能进入 RuntimeEstimator
        var estimatorInput = RuntimeEstimator.Inputs()
        estimatorInput.externalConnected = true
        estimatorInput.isCharging = true
        estimatorInput.currentLevel = 75
        estimatorInput.now = clock.now()
        estimatorInput.chargeTargetPercent = expiredSnapshot.targetPercent.map(Double.init)
        estimatorInput.snapshots = [
            BatterySnapshot(timestamp: clock.now().addingTimeInterval(-600), level: 70, isCharging: true, wattage: 20, externalConnected: true),
            BatterySnapshot(timestamp: clock.now(), level: 75, isCharging: true, wattage: 20, externalConnected: true)
        ]
        #expect(RuntimeEstimator.chargeEstimate(estimatorInput) == nil)

        // 验证过期目标不能触发充满/目标提醒
        let evidence = ChargeCompletionEvidence(targetPercent: 80, policyRevision: 1, startLevel: 79)
        let canNotify = NotificationPolicy.shouldSendFullCharge(
            level: 80,
            externalConnected: true,
            wasCharging: true,
            isCharging: false,
            targetPercent: expiredSnapshot.targetPercent,
            completionEvidence: evidence,
            policyRevision: 1,
            fullChargeEnabled: true,
            permissionValid: true,
            lastNotificationAt: nil,
            now: clock.now()
        )
        #expect(!canNotify)

        // 验证完成追踪器不会接受过期 nil 目标
        var tracker = ChargeCompletionTracker()
        _ = tracker.observe(pluggedIn: true, isCharging: true, level: 79, targetPercent: 80, policyRevision: 1)
        let completed = tracker.observe(pluggedIn: true, isCharging: false, level: 80, targetPercent: expiredSnapshot.targetPercent, policyRevision: 1)
        #expect(completed == nil)
    }

    @Test("过期后触发刷新成功恢复有效目标")
    @MainActor func recoversAfterExpiration() async {
        let clock = ControllableClock(now)
        let runner = ControllablePolicyRunner()
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { monitor.snapshot.targetPercent == 80 }
        #expect(monitor.snapshot.targetPercent == 80)

        // 步进到过期后 +1 秒，系统设置已变为 95%
        clock.set(now.addingTimeInterval(ChargePolicyMonitor.cacheTTL + 1))
        runner.setTarget(95)
        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { monitor.snapshot.targetPercent == 95 }

        #expect(runner.readCount == 2)
        #expect(monitor.snapshot.status == .configured)
        #expect(monitor.snapshot.targetPercent == 95)
    }

    @Test("读取失败如实降级且随后成功可恢复")
    @MainActor func failureDegradesAndRecovers() async {
        let clock = ControllableClock(now)
        let runner = ControllablePolicyRunner()
        runner.setFail(true)
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        monitor.refreshIfNeeded(force: true, now: clock.now())
        await waitUntil { monitor.snapshot.readAt != nil }
        #expect(monitor.snapshot.status == .unavailable)
        #expect(monitor.snapshot.targetPercent == nil)

        // 恢复正常
        runner.setFail(false)
        clock.advance(by: 35)
        monitor.refreshIfNeeded(force: true, now: clock.now())
        await waitUntil { monitor.snapshot.targetPercent == 80 }
        #expect(monitor.snapshot.status == .configured)
        #expect(monitor.snapshot.targetPercent == 80)
    }

    @Test("在途读取与待补读时停止：零回调零新读取且丢弃迟到结果")
    @MainActor func stopCancelsPendingAndDiscardsInFlightResult() async {
        let clock = ControllableClock(now)
        let runner = ControllablePolicyRunner()
        let firstGate = runner.holdNextRead()
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        var callbacks = 0
        monitor.onChange = { _, _ in callbacks += 1 }

        // 启动首次读取（in-flight）
        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { runner.readCount == 1 }
        #expect(runner.readCount == 1)

        // 限流窗口外发起强制刷新需求，由于正在读取，被记录为待补读
        clock.advance(by: 35)
        monitor.refreshIfNeeded(force: true, now: clock.now())

        // 在读取完成前停止，再放行在途读取
        monitor.stop()
        firstGate.signal()
        let readsAtStop = runner.readCount
        #expect(readsAtStop == 1)

        // 等待在途任务完成以及原预定重试窗口
        try? await Task.sleep(nanoseconds: 120_000_000)

        // 停止后：没有发起新读取，没有触发回调，快照保持初始不可用
        #expect(runner.readCount == 1)
        #expect(callbacks == 0)
        #expect(monitor.snapshot.targetPercent == nil)

        // 重复调用 stop 幂等安全
        monitor.stop()
        #expect(runner.readCount == 1)
        #expect(callbacks == 0)
    }

    @Test("停止后恢复：旧任务迟到不覆盖新状态且保持单进程")
    @MainActor func resumeAfterStopDiscardsOldResultAndRunsPendingWithoutParallelProcesses() async {
        let clock = ControllableClock(now)
        let runner = ControllablePolicyRunner()
        let firstGate = runner.holdNextRead()
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        var publishedTargets: [Int?] = []
        monitor.onChange = { snap, _ in publishedTargets.append(snap.targetPercent) }

        // 首次读取（返回 80）
        runner.setTarget(80)
        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { runner.readCount == 1 }
        #expect(runner.readCount == 1)

        // 停止监视器
        monitor.stop()

        // 恢复监视器并将外部目标改为 95%
        runner.setTarget(95)
        monitor.start()

        // 恢复后请求强制刷新；此时旧任务仍在底层跑，新请求应排队，不产生并发读取
        clock.advance(by: 35)
        monitor.refreshIfNeeded(force: true, now: clock.now())
        #expect(runner.readCount == 1) // 依然只有 1 个底层任务在跑

        // 放行旧任务，等待旧任务结束并完成新任务
        firstGate.signal()
        await waitUntil { monitor.snapshot.targetPercent == 95 }

        // 旧任务结果 80% 被丢弃，未发布；新任务执行完成，发布 95%
        #expect(runner.readCount == 2)
        #expect(publishedTargets == [95])
        #expect(monitor.snapshot.targetPercent == 95)
    }

    @Test("chargingEstimateTargetPercent 覆盖全部策略档位与无上限状态，且不改变 targetPercent")
    func chargingEstimateTargetPercentCoversAllPolicyStatuses() {
        for tier in ChargeLimitTarget.allCases {
            let configured = parse(onePolicy(terminated: 0, target: tier.rawValue))
            #expect(configured.status == .configured)
            #expect(configured.targetPercent == tier.rawValue)
            #expect(configured.chargingEstimateTargetPercent == tier.rawValue)
        }

        let noLimit = parse("No battery level limits set\n")
        #expect(noLimit.status == .noActiveLimit)
        #expect(noLimit.targetPercent == nil)
        #expect(noLimit.chargingEstimateTargetPercent == 100)

        let emptyList = parse("Battery level limits:\n(\n)\n")
        #expect(emptyList.status == .noActiveLimit)
        #expect(emptyList.targetPercent == nil)
        #expect(emptyList.chargingEstimateTargetPercent == 100)

        let staleFromConfigured = parse(onePolicy(target: 80)).expiring(at: now.addingTimeInterval(900), ttl: 900)
        #expect(staleFromConfigured.status == .stale)
        #expect(staleFromConfigured.chargingEstimateTargetPercent == nil)

        let staleFromNoLimit = noLimit.expiring(at: now.addingTimeInterval(900), ttl: 900)
        #expect(staleFromNoLimit.status == .stale)
        #expect(staleFromNoLimit.chargingEstimateTargetPercent == nil)

        let unavailable = parse(liveDuplicateFixture, exitCode: 1)
        #expect(unavailable.status == .unavailable)
        #expect(unavailable.chargingEstimateTargetPercent == nil)

        let unknown = parse(onePolicy(reason: "futurePolicy", target: 80))
        #expect(unknown.status == .unknownPolicy)
        #expect(unknown.chargingEstimateTargetPercent == nil)

        let conflict = parse("""
        Battery level limits:
        (
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 80; },
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 90; }
        )
        """)
        #expect(conflict.status == .conflictingPolicies)
        #expect(conflict.chargingEstimateTargetPercent == nil)
    }

    @Test("completionNotificationTargetPercent 在确认无上限时映射为 100 且不污染 targetPercent")
    func completionNotificationTargetPercentCoversAllPolicyStatuses() {
        for tier in ChargeLimitTarget.allCases {
            let configured = parse(onePolicy(terminated: 0, target: tier.rawValue))
            #expect(configured.targetPercent == tier.rawValue)
            #expect(configured.completionNotificationTargetPercent == tier.rawValue)
        }

        let noLimit = parse("No battery level limits set\n")
        #expect(noLimit.status == .noActiveLimit)
        #expect(noLimit.targetPercent == nil)
        #expect(noLimit.completionNotificationTargetPercent == 100)

        let terminatedOnly = parse(onePolicy(terminated: 1, target: 80))
        #expect(terminatedOnly.status == .noActiveLimit)
        #expect(terminatedOnly.targetPercent == nil)
        #expect(terminatedOnly.completionNotificationTargetPercent == 100)

        let staleFromNoLimit = noLimit.expiring(at: now.addingTimeInterval(900), ttl: 900)
        #expect(staleFromNoLimit.status == .stale)
        #expect(staleFromNoLimit.targetPercent == nil)
        #expect(staleFromNoLimit.completionNotificationTargetPercent == nil)

        let unavailable = parse(liveDuplicateFixture, exitCode: 1)
        #expect(unavailable.completionNotificationTargetPercent == nil)

        let unknown = parse(onePolicy(reason: "futurePolicy", target: 80))
        #expect(unknown.completionNotificationTargetPercent == nil)

        let conflict = parse("""
        Battery level limits:
        (
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 80; },
            { Terminated = 0; chargeSocLimitReason = manualChargeLimit; chargeSocLimitSoc = 85; }
        )
        """)
        #expect(conflict.completionNotificationTargetPercent == nil)
    }

    @Test("确认无上限状态在 TTL 到期后转为 stale，且重新刷新同状态不破坏策略版本")
    @MainActor func noActiveLimitExpiresAtTTLAndRecoversOnRefresh() async {
        let clock = ControllableClock(now)
        let runner = ControllablePolicyRunner()
        runner.setNoActiveLimit(true)
        let monitor = ChargePolicyMonitor(runner: runner, clock: { clock.now() })

        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { monitor.snapshot.status == .noActiveLimit }
        let initialRevision = monitor.revision
        #expect(monitor.snapshot.targetPercent == nil)
        #expect(monitor.snapshot.completionNotificationTargetPercent == 100)

        clock.set(now.addingTimeInterval(ChargePolicyMonitor.cacheTTL))
        #expect(monitor.snapshot.status == .stale)
        #expect(monitor.snapshot.completionNotificationTargetPercent == nil)

        clock.advance(by: 1)
        monitor.refreshIfNeeded(now: clock.now())
        await waitUntil { runner.readCount == 2 && monitor.snapshot.status == .noActiveLimit }
        #expect(monitor.snapshot.targetPercent == nil)
        #expect(monitor.snapshot.completionNotificationTargetPercent == 100)
        #expect(monitor.revision == initialRevision)
    }
}
