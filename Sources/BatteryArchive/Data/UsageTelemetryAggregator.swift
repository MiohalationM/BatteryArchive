import Foundation

/// Joint power/screen accounting at existing read cadence. Bounded to one five-minute
/// bucket plus completed buckets awaiting the caller's immediate drain.
struct UsageTelemetryAggregator {
    struct Observation: Sendable {
        var date: Date
        var externalConnected: Bool?
        var screenOn: Bool?
        var level: Double?
        var dischargePower: Double?
        var powerIsEstimated = false
        var expectedInterval: TimeInterval = 15
        var timeZone: TimeZone = .current
        var monotonicTime: TimeInterval? = nil
    }

    private enum UnknownGapReason {
        case samplingGap
        case readFailure
    }

    private enum ClockStep {
        case reject
        case normal
        case rollback(TimeInterval)
        case forwardJump(TimeInterval)
    }

    private static let clockJumpThreshold: TimeInterval = 30
    /// 单次 advance 最多连续切分 24 小时（288 个 5 分钟桶）的读取失败缺口，防极端跳变 OOM。
    private static let maxReadFailureBucketsPerAdvance = 288

    let measurementEpoch: UUID
    let runID: UUID
    private var current: UsageBucket?
    private var completed: [UsageBucket] = []
    private var previous: Observation?
    private var cursor: Date?
    private var lastMonotonicTime: TimeInterval?
    private var sleepingSince: Date?
    private var continuityID = UUID()
    private var sessionID: UUID?
    private var currentSessionStartObserved = false
    private var hasObservedKnownState = false
    private var unknownReason: UnknownGapReason = .samplingGap
    private var pendingClockRollbacks = 0
    private var rollbackEpoch: UInt64 = 0
    private var stopped = false
    private var liveLevel: Double?
    private var zone: TimeZone = .current

    init(measurementEpoch: UUID, runID: UUID = UUID()) {
        self.measurementEpoch = measurementEpoch
        self.runID = runID
    }

    mutating func observe(_ observation: Observation) {
        guard !stopped, sleepingSince == nil,
              observation.date.timeIntervalSince1970.isFinite,
              observation.expectedInterval.isFinite, observation.expectedInterval > 0 else { return }
        switch classifyClockStep(to: observation.date, monotonicTime: observation.monotonicTime) {
        case .reject:
            return
        case .rollback(let mono):
            handleWallClockRollback(to: observation.date, monotonicTime: mono)
        case .forwardJump(let mono):
            handleForwardClockJump(to: observation.date, monotonicTime: mono)
        case .normal:
            advance(to: observation.date)
        }
        let zoneChanged = zone.identifier != observation.timeZone.identifier
        if zoneChanged {
            closeBucket()
            continuityID = UUID()
            sessionID = nil
            currentSessionStartObserved = false
        }
        zone = observation.timeZone
        let hadSamplingGap: Bool
        if let old = previous,
           observation.date.timeIntervalSince(old.date) > hold(for: old) {
            continuityID = UUID()
            sessionID = nil
            currentSessionStartObserved = false
            hadSamplingGap = true
        } else {
            hadSamplingGap = false
        }
        let oldActivity = previous.map(activity)
        let newActivity = activity(observation)
        if oldActivity == .unknown || newActivity == .unknown {
            continuityID = UUID()
        }
        if newActivity == .unknown {
            unknownReason = .readFailure
        } else {
            hasObservedKnownState = true
            unknownReason = .samplingGap
        }
        if newActivity.isOnBattery {
            if oldActivity?.isOnBattery != true || sessionID == nil {
                sessionID = UUID()
                // 仅在连续无缺口且同一直区亲眼观察到「接电→离电」切换时，起点才视为完整记录。
                currentSessionStartObserved = (oldActivity == .onPower && !hadSamplingGap && !zoneChanged)
            }
        } else {
            // 仅在连续无缺口且同一直区亲眼观察到「离电→接电」切换时，标记该离电段终点已完整记录。
            if oldActivity?.isOnBattery == true, newActivity == .onPower, !hadSamplingGap, !zoneChanged {
                markLatestBatterySpanEndObserved(matching: sessionID, at: observation.date)
            }
            sessionID = nil
            currentSessionStartObserved = false
        }
        // Flush immediately at plug boundaries; even a two-minute zero-SOC-drop
        // excursion is durable, with no percentage/duration display threshold.
        if let oldActivity, oldActivity.isOnBattery != newActivity.isOnBattery {
            if oldActivity != .unknown, newActivity != .unknown {
                if current != nil {
                    appendLevel(observation.level, at: observation.date)
                } else if !completed.isEmpty, completed[completed.count - 1].end == observation.date {
                    // 若插拔恰好落在 5 分钟边界，advance(to:) 已先封存桶，需把边界终点电量补入该桶。
                    appendLevel(observation.level, at: observation.date, to: &completed[completed.count - 1])
                }
            }
            closeBucket()
        }
        previous = observation
        cursor = observation.date
        if let mono = validMonotonic(observation.monotonicTime) {
            lastMonotonicTime = mono
        }
        liveLevel = newActivity == .unknown ? nil : sanitizedLevel(observation.level)
        ensureBucket(at: observation.date)
        if newActivity != .unknown {
            appendLevel(liveLevel, at: observation.date)
        }
    }

    mutating func changeScreen(on: Bool, at date: Date, monotonicTime: TimeInterval? = nil) {
        guard !stopped, sleepingSince == nil, date.timeIntervalSince1970.isFinite else { return }
        switch classifyClockStep(to: date, monotonicTime: monotonicTime) {
        case .reject:
            return
        case .rollback(let mono):
            handleWallClockRollback(to: date, monotonicTime: mono)
            return
        case .forwardJump(let mono):
            handleForwardClockJump(to: date, monotonicTime: mono)
            return
        case .normal:
            advance(to: date)
            if let mono = validMonotonic(monotonicTime) {
                lastMonotonicTime = mono
            }
        }
        // A screen event cannot refresh stale power/source evidence.
        let wasActivity = previous.map(activity)
        previous?.screenOn = on
        if let newActivity = previous.map(activity), newActivity.isOnBattery,
           wasActivity?.isOnBattery != true, sessionID == nil {
            sessionID = UUID()
            currentSessionStartObserved = false
        }
    }

    mutating func invalidate(at date: Date, monotonicTime: TimeInterval? = nil) {
        guard !stopped, date.timeIntervalSince1970.isFinite else { return }
        switch classifyClockStep(to: date, monotonicTime: monotonicTime) {
        case .reject:
            return
        case .rollback(let mono):
            handleWallClockRollback(to: date, monotonicTime: mono)
            unknownReason = .readFailure
            return
        case .forwardJump(let mono):
            handleForwardClockJump(to: date, monotonicTime: mono)
            unknownReason = .readFailure
            return
        case .normal:
            advance(to: date)
            if let mono = validMonotonic(monotonicTime) {
                lastMonotonicTime = mono
            }
        }
        previous = nil
        liveLevel = nil
        sessionID = nil
        currentSessionStartObserved = false
        unknownReason = .readFailure
        continuityID = UUID()
        cursor = date
    }

    mutating func sleep(at date: Date, monotonicTime: TimeInterval? = nil) {
        guard !stopped, sleepingSince == nil, date.timeIntervalSince1970.isFinite else { return }
        switch classifyClockStep(to: date, monotonicTime: monotonicTime) {
        case .reject:
            return
        case .rollback(let mono):
            handleWallClockRollback(to: date, monotonicTime: mono)
            unknownReason = .samplingGap
            sleepingSince = date
            return
        case .forwardJump(let mono):
            handleForwardClockJump(to: date, monotonicTime: mono)
            unknownReason = .samplingGap
            sleepingSince = date
            return
        case .normal:
            advance(to: date)
            if let mono = validMonotonic(monotonicTime) {
                lastMonotonicTime = mono
            }
        }
        closeBucket()
        previous = nil
        liveLevel = nil
        sessionID = nil
        currentSessionStartObserved = false
        unknownReason = .samplingGap
        continuityID = UUID()
        cursor = date
        sleepingSince = date
    }

    mutating func wake(at date: Date, monotonicTime: TimeInterval? = nil) {
        guard !stopped, let start = sleepingSince, date.timeIntervalSince1970.isFinite else { return }
        let mono = validMonotonic(monotonicTime)
        if let mono, let prevMono = lastMonotonicTime, mono < prevMono {
            return
        }
        if date < start {
            // 时钟回拨时绝不卡死在睡眠状态，清空睡眠标记并断开连续性，避免写回重叠桶。
            closeBucket()
            sleepingSince = nil
            continuityID = UUID()
            sessionID = nil
            currentSessionStartObserved = false
            unknownReason = .samplingGap
            previous = nil
            liveLevel = nil
            pendingClockRollbacks += 1
            rollbackEpoch &+= 1
            cursor = date
            if let mono { lastMonotonicTime = mono }
            return
        }
        // Paired in-process sleep/wake only. No sleep power or source extrapolation.
        // Note: systemUptime pauses during macOS sleep, so wall-clock delta > mono delta is expected here.
        cursor = max(start, date.addingTimeInterval(-30 * 86_400))
        while let from = cursor, from < date {
            let windowEnd = boundary(after: from)
            let end = min(date, windowEnd)
            addInterval(from: from, to: end, activity: .sleep, power: nil, estimated: false)
            cursor = end
            if end == windowEnd { closeBucket() }
        }
        closeBucket()
        sleepingSince = nil
        continuityID = UUID()
        sessionID = nil
        currentSessionStartObserved = false
        unknownReason = .samplingGap
        previous = nil
        cursor = date
        if let mono { lastMonotonicTime = mono }
    }

    mutating func stop(at date: Date, monotonicTime: TimeInterval? = nil) {
        guard !stopped else { return }
        // An unpaired sleep is deliberately not counted on shutdown.
        if sleepingSince == nil, date.timeIntervalSince1970.isFinite {
            if case .normal = classifyClockStep(to: date, monotonicTime: monotonicTime) {
                advance(to: date)
            }
        }
        if let mono = validMonotonic(monotonicTime),
           lastMonotonicTime == nil || mono >= lastMonotonicTime! {
            lastMonotonicTime = mono
        }
        closeBucket()
        previous = nil
        sleepingSince = nil
        sessionID = nil
        currentSessionStartObserved = false
        stopped = true
    }

    mutating func takeCompleted() -> [UsageBucket] {
        let result = completed
        completed.removeAll(keepingCapacity: true)
        return result
    }

    func preview(at date: Date) -> [UsageBucket] {
        var copy = self
        // Do not project sleep without its matching wake evidence.
        if copy.sleepingSince == nil { copy.advance(to: date) }
        var result = copy.completed
        if let current = copy.current, shouldEmit(current) {
            result.append(current)
        }
        return result.map { var bucket = $0; bucket.isLive = true; return bucket }
    }

    private func validMonotonic(_ value: TimeInterval?) -> TimeInterval? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private func classifyClockStep(to date: Date, monotonicTime: TimeInterval?) -> ClockStep {
        let mono = validMonotonic(monotonicTime)
        if let mono, let prevMono = lastMonotonicTime, mono < prevMono {
            return .reject
        }
        guard let cursor else { return .normal }
        let wallDelta = date.timeIntervalSince(cursor)
        if wallDelta < 0 {
            if let mono, let prevMono = lastMonotonicTime, mono >= prevMono {
                return .rollback(mono)
            }
            return .reject
        }
        if let mono, let prevMono = lastMonotonicTime,
           abs(wallDelta - (mono - prevMono)) > Self.clockJumpThreshold {
            return .forwardJump(mono)
        }
        return .normal
    }

    private mutating func handleWallClockRollback(to date: Date, monotonicTime: TimeInterval) {
        closeBucket()
        continuityID = UUID()
        sessionID = nil
        currentSessionStartObserved = false
        previous = nil
        liveLevel = nil
        pendingClockRollbacks += 1
        rollbackEpoch &+= 1
        cursor = date
        lastMonotonicTime = monotonicTime
    }

    private mutating func handleForwardClockJump(to date: Date, monotonicTime: TimeInterval) {
        closeBucket()
        continuityID = UUID()
        sessionID = nil
        currentSessionStartObserved = false
        previous = nil
        liveLevel = nil
        cursor = date
        lastMonotonicTime = monotonicTime
    }

    private func activity(_ observation: Observation) -> UsageActivity {
        switch (observation.externalConnected, observation.screenOn) {
        case (true, _): .onPower
        case (false, true): .batteryScreenOn
        case (false, false): .batteryScreenOff
        default: .unknown
        }
    }

    private func hold(for observation: Observation) -> TimeInterval {
        min(30, 2 * observation.expectedInterval)
    }

    private func sanitizedLevel(_ value: Double?) -> Double? {
        guard let value, value.isFinite, (0...100).contains(value) else { return nil }
        return value
    }

    private func boundary(after date: Date) -> Date {
        let grid = Date(timeIntervalSince1970: (floor(date.timeIntervalSince1970 / 300) + 1) * 300)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let dayStart = calendar.startOfDay(for: date)
        let midnight = calendar.dateInterval(of: .day, for: dayStart)?.end
            ?? calendar.date(byAdding: .day, value: 1, to: dayStart)
            ?? grid
        return min(grid, midnight)
    }

    private mutating func ensureBucket(at date: Date) {
        if current == nil {
            let bucketID = rollbackEpoch == 0
                ? "\(runID.uuidString):\(date.timeIntervalSince1970)"
                : "\(runID.uuidString):r\(rollbackEpoch):\(date.timeIntervalSince1970)"
            var bucket = UsageBucket(
                id: bucketID,
                measurementEpoch: measurementEpoch, runID: runID,
                timeZoneID: zone.identifier, start: date, end: date
            )
            if pendingClockRollbacks > 0 {
                bucket.clockRollbackCount = pendingClockRollbacks
                pendingClockRollbacks = 0
            }
            current = bucket
        }
    }

    private mutating func markLatestBatterySpanEndObserved(matching targetSessionID: UUID?, at date: Date) {
        guard let targetSessionID else { return }
        if var bucket = current, let lastIndex = bucket.spans.indices.last,
           bucket.spans[lastIndex].activity.isOnBattery,
           bucket.spans[lastIndex].sessionID == targetSessionID,
           bucket.spans[lastIndex].end == date {
            bucket.spans[lastIndex].endObserved = true
            current = bucket
            return
        }
        if !completed.isEmpty,
           let lastIndex = completed[completed.count - 1].spans.indices.last,
           completed[completed.count - 1].spans[lastIndex].activity.isOnBattery,
           completed[completed.count - 1].spans[lastIndex].sessionID == targetSessionID,
           completed[completed.count - 1].spans[lastIndex].end == date {
            completed[completed.count - 1].spans[lastIndex].endObserved = true
        }
    }

    private mutating func advance(to date: Date) {
        guard let initialCursor = cursor, date >= initialCursor else { return }
        let trackReadFailure = hasObservedKnownState && unknownReason == .readFailure
        // If no known observation exists (and not tracking a confirmed mid-run read failure),
        // skip long empty gaps rather than allocating unbounded empty buckets.
        if previous == nil, current == nil, !trackReadFailure {
            cursor = date
            return
        }
        var readFailureBucketsEmitted = 0
        while let from = cursor, from < date {
            let windowEnd = boundary(after: from)
            var end = min(date, windowEnd)
            var state: UsageActivity = .unknown
            var power: Double?
            var estimated = false
            var gapReason: UnknownGapReason = unknownReason
            if let observation = previous {
                let validUntil = observation.date.addingTimeInterval(hold(for: observation))
                if from < validUntil {
                    end = min(end, validUntil)
                    state = activity(observation)
                    if state == .unknown {
                        gapReason = .readFailure
                    }
                    if state.isOnBattery, let watts = observation.dischargePower,
                       watts.isFinite, (0..<500).contains(watts) {
                        power = watts
                        estimated = observation.powerIsEstimated
                    }
                } else {
                    // 超过单样本保持上限仍未收到新观测：归类为采样超时缺口
                    gapReason = .samplingGap
                }
            }
            addInterval(from: from, to: end, activity: state, power: power, estimated: estimated,
                        gapReason: gapReason)
            cursor = end
            if end == windowEnd {
                if state == .unknown, gapReason == .readFailure, hasObservedKnownState {
                    readFailureBucketsEmitted += 1
                }
                closeBucket()
            }
            if state == .unknown {
                sessionID = nil
                currentSessionStartObserved = false
                continuityID = UUID()
                let continueReadFailure = hasObservedKnownState
                    && gapReason == .readFailure
                    && readFailureBucketsEmitted < Self.maxReadFailureBucketsPerAdvance
                if current == nil, end < date, !continueReadFailure {
                    // Remaining time is still unknown; absence is the gap.
                    cursor = date
                    break
                }
            }
        }
    }

    private mutating func addInterval(
        from: Date, to: Date, activity: UsageActivity, power: Double?, estimated: Bool,
        gapReason: UnknownGapReason = .samplingGap
    ) {
        guard to > from else { return }
        ensureBucket(at: from)
        guard var bucket = current else { return }
        let seconds = to.timeIntervalSince(from)
        let wh = power.map { $0 * seconds / 3600 } ?? 0
        let valid = power == nil ? 0 : seconds
        let estimatedSeconds = estimated ? valid : 0
        bucket.end = to
        switch activity {
        case .onPower: bucket.onPowerSeconds += seconds
        case .batteryScreenOn: bucket.screenOnSeconds += seconds
        case .batteryScreenOff: bucket.screenOffSeconds += seconds
        case .sleep: bucket.sleepSeconds += seconds
        case .unknown:
            bucket.unknownSeconds += seconds
            switch gapReason {
            case .readFailure:
                // 仅在已进入运行态（观测过已知状态）后计入读取失败时长；启动初期未知态不产出空诊断桶。
                if hasObservedKnownState {
                    bucket.readFailureSeconds = (bucket.readFailureSeconds ?? 0) + seconds
                }
            case .samplingGap:
                bucket.samplingGapSeconds = (bucket.samplingGapSeconds ?? 0) + seconds
            }
        }
        bucket.dischargeWh += wh
        bucket.powerSeconds += valid
        bucket.estimatedSeconds += estimatedSeconds
        if let last = bucket.spans.last, last.end == from, last.activity == activity,
           last.sessionID == (activity.isOnBattery ? sessionID : nil),
           last.continuityID == continuityID {
            let index = bucket.spans.count - 1
            bucket.spans[index].end = to
            bucket.spans[index].dischargeWh += wh
            bucket.spans[index].powerSeconds += valid
            bucket.spans[index].estimatedSeconds += estimatedSeconds
        } else if bucket.spans.count < 64 {
            bucket.spans.append(UsageSpan(
                start: from, end: to, activity: activity,
                sessionID: activity.isOnBattery ? sessionID : nil, continuityID: continuityID,
                dischargeWh: wh, powerSeconds: valid, estimatedSeconds: estimatedSeconds,
                startObserved: activity.isOnBattery ? currentSessionStartObserved : nil,
                endObserved: activity.isOnBattery ? false : nil
            ))
        } else {
            bucket.detailsTruncated = true
        }
        current = bucket
    }

    private mutating func appendLevel(_ raw: Double?, at date: Date) {
        guard var bucket = current else { return }
        appendLevel(raw, at: date, to: &bucket)
        current = bucket
    }

    private func appendLevel(_ raw: Double?, at date: Date, to bucket: inout UsageBucket) {
        guard let level = sanitizedLevel(raw) else { return }
        // Keep both ends of flat runs and all observed changes, capped per bucket.
        if let last = bucket.levels.last, last.date == date {
            bucket.levels.removeLast()
        }
        if bucket.levels.count >= 2 {
            let a = bucket.levels[bucket.levels.count - 2]
            let b = bucket.levels[bucket.levels.count - 1]
            if a.level == level, b.level == level,
               a.continuityID == continuityID, b.continuityID == continuityID {
                bucket.levels.removeLast()
            }
        }
        if bucket.levels.count == 64 {
            bucket.detailsTruncated = true
            // Preserve the first anchor and the latest values.
            bucket.levels.remove(at: 1)
        }
        bucket.levels.append(UsageLevelPoint(date: date, level: level, continuityID: continuityID))
    }

    private func shouldEmit(_ bucket: UsageBucket) -> Bool {
        bucket.duration > 0 && (
            bucket.knownSeconds > 0
                || (bucket.readFailureSeconds ?? 0) > 0
                || (bucket.clockRollbackCount ?? 0) > 0
        )
    }

    private mutating func closeBucket() {
        guard let bucket = current else { return }
        if shouldEmit(bucket) { completed.append(bucket) }
        current = nil
    }
}
