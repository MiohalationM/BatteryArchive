import Foundation

/// 已确认的系统充电上限档位。未支持或未读取到的值保持未知。
enum ChargeLimitTarget: Int, CaseIterable, Equatable {
    case percent80 = 80
    case percent85 = 85
    case percent90 = 90
    case percent95 = 95
    case percent100 = 100
}

struct ChargePolicySnapshot: Equatable {
    enum Status: Equatable {
        case configured
        case noActiveLimit
        case conflictingPolicies
        case unknownPolicy
        case unavailable
        case stale
    }

    var status: Status
    var targetPercent: Int?
    var source: String
    var readAt: Date?

    static let sourceName = "pmset -g battlimit"

    static func unavailable(readAt: Date? = nil) -> ChargePolicySnapshot {
        ChargePolicySnapshot(status: .unavailable, targetPercent: nil, source: sourceName, readAt: readAt)
    }

    func expiring(at now: Date, ttl: TimeInterval) -> ChargePolicySnapshot {
        guard let readAt else { return self }
        let age = now.timeIntervalSince(readAt)
        guard age >= ttl || age < 0 else { return self }
        return ChargePolicySnapshot(status: .stale, targetPercent: nil, source: source, readAt: readAt)
    }

    var statusLabel: String {
        switch status {
        case .configured: targetPercent.map { "\($0)%" } ?? "目标未知"
        case .noActiveLimit: "未设置"
        case .conflictingPolicies: "策略冲突"
        case .unknownPolicy: "暂不可用"
        case .unavailable: "暂不可用"
        case .stale: "读取已过期"
        }
    }

    /// 充电时间估算目标：已配置上限用 `targetPercent`，明确无上限（`.noActiveLimit`）用 `100`，
    /// 冲突/未知/不可用/过期保持 `nil`；不改变 `targetPercent` 在 UI 中的展示语义。
    var chargingEstimateTargetPercent: Int? {
        switch status {
        case .configured:
            targetPercent
        case .noActiveLimit:
            100
        case .conflictingPolicies, .unknownPolicy, .unavailable, .stale:
            nil
        }
    }

    /// 充满/到达上限提醒目标：已配置上限用 `targetPercent`，明确无上限（`.noActiveLimit`）用 `100`，
    /// 冲突/未知/不可用/过期保持 `nil`（不猜测上限，也不把 `.noActiveLimit` 写回 `targetPercent`）。
    var completionNotificationTargetPercent: Int? {
        chargingEstimateTargetPercent
    }

    static func shouldRefresh(lastReadAt: Date?, now: Date, ttl: TimeInterval) -> Bool {
        guard let lastReadAt else { return true }
        let age = now.timeIntervalSince(lastReadAt)
        return age < 0 || age >= ttl
    }
}

struct ChargePolicyCommandResult: Equatable, Sendable {
    let stdout: String?
    let exitCode: Int32?
}

/// 对 pmset 非公开输出采用严格、可降级解析；未知版本格式不产生可用目标。
enum ChargePolicyParser {
    private struct PolicyIdentity: Hashable {
        let reason: String
        let target: Int
    }

    static func parse(_ command: ChargePolicyCommandResult, readAt: Date) -> ChargePolicySnapshot {
        guard command.exitCode == 0, let stdout = command.stdout else {
            return .unavailable(readAt: readAt)
        }
        let output = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if output.caseInsensitiveCompare("No battery level limits set") == .orderedSame {
            return ChargePolicySnapshot(status: .noActiveLimit, targetPercent: nil,
                                        source: ChargePolicySnapshot.sourceName, readAt: readAt)
        }
        let heading = "Battery level limits:"
        guard output.hasPrefix(heading) else {
            return ChargePolicySnapshot(status: .unknownPolicy, targetPercent: nil,
                                        source: ChargePolicySnapshot.sourceName, readAt: readAt)
        }

        let payload = output.dropFirst(heading.count).trimmingCharacters(in: .whitespacesAndNewlines)
        guard payload.hasPrefix("("), payload.hasSuffix(")"),
              let blocks = dictionaryBlocks(in: String(payload.dropFirst().dropLast())) else {
            return ChargePolicySnapshot(status: .unknownPolicy, targetPercent: nil,
                                        source: ChargePolicySnapshot.sourceName, readAt: readAt)
        }
        if blocks.isEmpty {
            let isExplicitlyEmpty = payload.range(
                of: #"^\(\s*\)$"#,
                options: .regularExpression
            ) != nil
            let status: ChargePolicySnapshot.Status = isExplicitlyEmpty ? .noActiveLimit : .unknownPolicy
            return ChargePolicySnapshot(status: status, targetPercent: nil,
                                        source: ChargePolicySnapshot.sourceName, readAt: readAt)
        }

        var active: Set<PolicyIdentity> = []
        for block in blocks {
            guard let fields = fields(in: block),
                  let terminated = parseBoolean(fields["Terminated"]) else {
                return ChargePolicySnapshot(status: .unknownPolicy, targetPercent: nil,
                                            source: ChargePolicySnapshot.sourceName, readAt: readAt)
            }
            if terminated { continue }
            guard let reason = fields["chargeSocLimitReason"],
                  let rawTarget = fields["chargeSocLimitSoc"],
                  let target = Int(rawTarget), (0...100).contains(target) else {
                return ChargePolicySnapshot(status: .unknownPolicy, targetPercent: nil,
                                            source: ChargePolicySnapshot.sourceName, readAt: readAt)
            }
            active.insert(PolicyIdentity(reason: reason, target: target))
        }

        guard !active.isEmpty else {
            return ChargePolicySnapshot(status: .noActiveLimit, targetPercent: nil,
                                        source: ChargePolicySnapshot.sourceName, readAt: readAt)
        }
        guard active.count == 1, let policy = active.first else {
            return ChargePolicySnapshot(status: .conflictingPolicies, targetPercent: nil,
                                        source: ChargePolicySnapshot.sourceName, readAt: readAt)
        }
        guard policy.reason == "manualChargeLimit",
              ChargeLimitTarget(rawValue: policy.target) != nil else {
            return ChargePolicySnapshot(status: .unknownPolicy, targetPercent: nil,
                                        source: ChargePolicySnapshot.sourceName, readAt: readAt)
        }
        return ChargePolicySnapshot(status: .configured, targetPercent: policy.target,
                                    source: ChargePolicySnapshot.sourceName, readAt: readAt)
    }

    private static func dictionaryBlocks(in output: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: #"\{([^{}]*)\}"#) else { return nil }
        let nsOutput = output as NSString
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: nsOutput.length))
        var blocks: [String] = []
        var cursor = 0
        for match in matches {
            guard match.numberOfRanges == 2,
                  separatorsOnly(nsOutput.substring(with: NSRange(location: cursor, length: match.range.location - cursor))) else {
                return nil
            }
            blocks.append(nsOutput.substring(with: match.range(at: 1)))
            cursor = NSMaxRange(match.range)
        }
        guard separatorsOnly(nsOutput.substring(from: cursor)) else { return nil }
        return blocks
    }

    private static func separatorsOnly(_ value: String) -> Bool {
        value.allSatisfy { $0.isWhitespace || $0 == "," }
    }

    private static func fields(in block: String) -> [String: String]? {
        var result: [String: String] = [:]
        for item in block.split(separator: ";") {
            let pair = item.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pair.isEmpty else { continue }
            guard let equals = pair.firstIndex(of: "=") else { return nil }
            let key = pair[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pair[pair.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty, !value.isEmpty, result[key] == nil else { return nil }
            result[key] = value
        }
        return result
    }

    private static func parseBoolean(_ raw: String?) -> Bool? {
        switch raw?.lowercased() {
        case "0", "false": false
        case "1", "true": true
        default: nil
        }
    }
}

protocol ChargePolicyCommandRunning: Sendable {
    func read() -> ChargePolicyCommandResult
}

struct SystemChargePolicyCommandRunner: ChargePolicyCommandRunning {
    private static let timeout: TimeInterval = 10

    private final class OutputBox: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        func set(_ value: Data) {
            lock.lock()
            data = value
            lock.unlock()
        }
        func get() -> Data {
            lock.lock()
            defer { lock.unlock() }
            return data
        }
    }

    func read() -> ChargePolicyCommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
        process.arguments = ["-g", "battlimit"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch {
            return ChargePolicyCommandResult(stdout: nil, exitCode: nil)
        }

        let box = OutputBox()
        let group = DispatchGroup()
        group.enter()
        DispatchQueue.global(qos: .utility).async {
            box.set(output.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + Self.timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        var timedOut = false
        if process.isRunning {
            timedOut = true
            process.terminate()
            let killDeadline = ProcessInfo.processInfo.systemUptime + 2
            while process.isRunning, ProcessInfo.processInfo.systemUptime < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
        }
        process.waitUntilExit()
        _ = group.wait(timeout: .now() + 2)
        guard !timedOut else {
            return ChargePolicyCommandResult(stdout: nil, exitCode: nil)
        }
        return ChargePolicyCommandResult(
            stdout: String(data: box.get(), encoding: .utf8),
            exitCode: process.terminationStatus
        )
    }
}

/// 缓存只读策略读取：调用方只在启动/界面打开/电源事件/低频定时器触发，
/// 每次运行间隔限流，读取后台串行且同一时刻最多一个 pmset 进程。
@MainActor
final class ChargePolicyMonitor {
    static let cacheTTL: TimeInterval = 15 * 60
    static let minimumForcedRefreshInterval: TimeInterval = 30
    static let fallbackRefreshInterval: TimeInterval = 15 * 60

    private let runner: any ChargePolicyCommandRunning
    private let clock: @Sendable () -> Date

    private var rawSnapshot = ChargePolicySnapshot.unavailable()
    private var lastConfirmedPolicy: (status: ChargePolicySnapshot.Status, targetPercent: Int?)?
    private(set) var revision = 0
    private var isStopped = false
    private var readInFlight = false
    private var lastAttemptAt: Date?
    private var hasPendingForcedRefresh = false
    private var hasPendingRefresh = false
    private var pendingRetryTask: Task<Void, Never>?
    private var expirationTask: Task<Void, Never>?
    private var activeGeneration = 0
    private var currentReadSequence = 0

    var onChange: ((ChargePolicySnapshot, Int) -> Void)?

    init(
        runner: any ChargePolicyCommandRunning = SystemChargePolicyCommandRunner(),
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.runner = runner
        self.clock = clock
    }

    /// 当前有效快照；超过 TTL 自动表现为 stale 状态，且 targetPercent 为 nil。
    var snapshot: ChargePolicySnapshot {
        rawSnapshot.expiring(at: clock(), ttl: Self.cacheTTL)
    }

    /// 恢复/启动监视器。
    func start() {
        guard isStopped else { return }
        isStopped = false
        activeGeneration += 1
    }

    /// 停止监视器：清除等待中的刷新需求，取消待执行重试与到期定时器。
    /// 在途的读取进程可安全执行完，但其结果被丢弃，不发布、不触发补读、不调度新定时器。
    func stop() {
        isStopped = true
        activeGeneration += 1
        hasPendingForcedRefresh = false
        hasPendingRefresh = false
        pendingRetryTask?.cancel()
        pendingRetryTask = nil
        expirationTask?.cancel()
        expirationTask = nil
    }

    func refreshIfNeeded(force: Bool = false, now: Date? = nil) {
        guard !isStopped else { return }
        let currentTime = now ?? clock()
        if let readAt = rawSnapshot.readAt,
           rawSnapshot.status != .stale {
            let age = currentTime.timeIntervalSince(readAt)
            if age >= Self.cacheTTL || age < 0 {
                publish(rawSnapshot.expiring(at: currentTime, ttl: Self.cacheTTL))
            }
        }

        if force {
            hasPendingForcedRefresh = true
        } else if ChargePolicySnapshot.shouldRefresh(lastReadAt: rawSnapshot.readAt, now: currentTime, ttl: Self.cacheTTL) {
            hasPendingRefresh = true
        }

        evaluatePendingRead(now: currentTime)
    }

    private func evaluatePendingRead(now: Date) {
        guard !isStopped else { return }
        guard !readInFlight else { return }

        guard hasPendingForcedRefresh || hasPendingRefresh else {
            scheduleExpirationIfNeeded(now: now)
            return
        }

        if hasPendingForcedRefresh {
            if let lastAttemptAt,
               now.timeIntervalSince(lastAttemptAt) >= 0,
               now.timeIntervalSince(lastAttemptAt) < Self.minimumForcedRefreshInterval {
                scheduleDelayedRetry(from: lastAttemptAt, now: now)
                return
            }
        }

        pendingRetryTask?.cancel()
        pendingRetryTask = nil
        hasPendingForcedRefresh = false
        hasPendingRefresh = false
        lastAttemptAt = now
        readInFlight = true

        activeGeneration += 1
        let generation = activeGeneration
        currentReadSequence += 1
        let sequence = currentReadSequence
        let runner = self.runner

        Task { @MainActor [weak self] in
            let result = await Task.detached(priority: .utility) { runner.read() }.value
            guard let self else { return }
            self.readInFlight = false

            guard !self.isStopped,
                  generation == self.activeGeneration,
                  sequence == self.currentReadSequence else {
                if !self.isStopped {
                    self.evaluatePendingRead(now: self.clock())
                }
                return
            }

            let readTime = self.clock()
            let parsed = ChargePolicyParser.parse(result, readAt: readTime)
            self.publish(parsed)
            self.scheduleExpirationIfNeeded(now: readTime)
            self.evaluatePendingRead(now: self.clock())
        }
    }

    private func scheduleDelayedRetry(from attemptTime: Date, now: Date) {
        guard !isStopped, pendingRetryTask == nil else { return }
        let remaining = max(0, Self.minimumForcedRefreshInterval - now.timeIntervalSince(attemptTime))
        pendingRetryTask = Task { @MainActor [weak self] in
            if remaining > 0 {
                try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            }
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            self.pendingRetryTask = nil
            self.evaluatePendingRead(now: self.clock())
        }
    }

    private func scheduleExpirationIfNeeded(now: Date) {
        expirationTask?.cancel()
        expirationTask = nil
        guard !isStopped else { return }
        guard let readAt = rawSnapshot.readAt,
              rawSnapshot.status == .configured || rawSnapshot.status == .noActiveLimit
        else { return }
        let expireAt = readAt.addingTimeInterval(Self.cacheTTL)
        let remaining = expireAt.timeIntervalSince(now)
        guard remaining > 0 else {
            publish(rawSnapshot.expiring(at: now, ttl: Self.cacheTTL))
            return
        }

        expirationTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000))
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            let currentNow = self.clock()
            if self.rawSnapshot.readAt == readAt {
                self.publish(self.rawSnapshot.expiring(at: currentNow, ttl: Self.cacheTTL))
                self.refreshIfNeeded(force: false, now: currentNow)
            }
        }
    }

    private func publish(_ next: ChargePolicySnapshot) {
        guard !isStopped else { return }
        guard next != rawSnapshot else { return }
        rawSnapshot = next
        if next.status != .stale {
            let nextIdentity = (status: next.status, targetPercent: next.targetPercent)
            let changed = lastConfirmedPolicy.map {
                $0.status != nextIdentity.status || $0.targetPercent != nextIdentity.targetPercent
            } ?? true
            if changed {
                revision += 1
            }
            lastConfirmedPolicy = nextIdentity
        }
        onChange?(snapshot, revision)
    }
}

/// 只在采样真正观察到 AC 阶段的充电开始后建立完成候选。
/// target/revision 固定在开始时，避免启动停充、策略修改或上限附近误报。
struct ChargeCompletionEvidence: Equatable {
    let targetPercent: Int
    let policyRevision: Int
    let startLevel: Double
}

struct ChargeCompletionTracker {
    private var hasBaseline = false
    private var previousPluggedIn = false
    private var previousCharging = false
    private var chargingStartedInCurrentPlugSession = false
    private var candidate: ChargeCompletionEvidence?

    mutating func reset() {
        hasBaseline = false
        previousPluggedIn = false
        previousCharging = false
        chargingStartedInCurrentPlugSession = false
        candidate = nil
    }

    mutating func observe(
        pluggedIn: Bool,
        isCharging: Bool,
        level: Double,
        targetPercent: Int?,
        policyRevision: Int
    ) -> ChargeCompletionEvidence? {
        if !hasBaseline {
            hasBaseline = true
            previousPluggedIn = pluggedIn
            previousCharging = isCharging
            return nil
        }

        let plugSessionContinues = pluggedIn && previousPluggedIn
        var completed: ChargeCompletionEvidence?
        if !pluggedIn || !plugSessionContinues {
            candidate = nil
            chargingStartedInCurrentPlugSession = false
        }

        if isCharging && plugSessionContinues && !previousCharging {
            chargingStartedInCurrentPlugSession = true
            candidate = Self.makeCandidate(level: level, target: targetPercent, revision: policyRevision)
        } else if isCharging && pluggedIn && !previousPluggedIn {
            // 同一采样已观察到拔电→接电且正在充电，记录该接电阶段的充电起点。
            chargingStartedInCurrentPlugSession = true
            candidate = Self.makeCandidate(level: level, target: targetPercent, revision: policyRevision)
        } else if isCharging && plugSessionContinues && chargingStartedInCurrentPlugSession && candidate == nil {
            // 接电起充瞬间策略尚在异步刷新（或曾短暂过期），待有效目标首次到达且仍低于目标时补建候选。
            candidate = Self.makeCandidate(level: level, target: targetPercent, revision: policyRevision)
        } else if !isCharging && previousCharging && plugSessionContinues {
            if let candidate,
               candidate.targetPercent == targetPercent,
               candidate.policyRevision == policyRevision,
               level >= Double(candidate.targetPercent),
               candidate.startLevel < Double(candidate.targetPercent) {
                completed = candidate
            }
            candidate = nil
            chargingStartedInCurrentPlugSession = false
        }

        previousPluggedIn = pluggedIn
        previousCharging = isCharging
        return completed
    }

    private static func makeCandidate(level: Double, target: Int?, revision: Int) -> ChargeCompletionEvidence? {
        guard let target, ChargeLimitTarget(rawValue: target) != nil,
              level.isFinite, level < Double(target) else { return nil }
        return ChargeCompletionEvidence(targetPercent: target, policyRevision: revision, startLevel: level)
    }
}
