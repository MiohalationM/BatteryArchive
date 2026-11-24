import Foundation
import AppKit
import IOKit
import IOKit.ps
import os

private let batteryReaderLogger = Logger(subsystem: "com.batteryarchive", category: "BatteryReader")

final class BatteryReader: @unchecked Sendable {
    struct PowerSourceInfo {
        let level: Double
        let isCharging: Bool
        let isPluggedIn: Bool
        /// IOPS public power-source description may omit this charge reason.
        let chargeStatus: String?
        let timeRemaining: Int
        var sourceStateAvailable = true
        var chargingStateAvailable = true
    }

    /// 同一轮采样的 IOPS 与 IORegistry 结果。调用方必须消费这一个快照，避免先后
    /// 两次读取跨过插拔边界，也避免每秒重复调用 IOPSCopyPowerSourcesInfo。
    struct BatteryReading {
        let powerSource: PowerSourceInfo
        let batteryInfo: BatteryInfo?
        /// 各字段的真实来源（provenance）
        let provenance: ReadingProvenance
        /// App 实际完成本轮读取的时刻。IORegistry/IOPS 不提供硬件时间戳，
        /// 这是唯一可信的「读取于」口径。
        let readAt: Date

        var resolvedExternalConnected: Bool? {
            guard powerSource.sourceStateAvailable, powerSource.chargingStateAvailable,
                  powerSource.isPluggedIn || !powerSource.isCharging else { return nil }
            if let info = batteryInfo {
                guard info.externalConnected == powerSource.isPluggedIn,
                      info.isCharging == powerSource.isCharging else { return nil }
            }
            return powerSource.isPluggedIn
        }

        /// 可信系统负载（与 BatterySnapshot.trustedSystemLoad 同一规则）：
        /// 实测遥测独立可信；估算负载只在明确离电时可信。
        var trustedSystemLoad: Double? {
            guard let info = batteryInfo, info.systemPowerAvailable, info.systemPower > 0 else { return nil }
            if !info.systemPowerIsEstimated { return info.systemPower }
            return resolvedExternalConnected == false ? info.systemPower : nil
        }

        /// 电池功率方向通道规则：
        /// 1. 接电且充电、功率可用 → charge；
        /// 2. 明确离电且未充电、功率可用 → discharge；
        /// 3. 接电未充电、状态自相矛盾（如离电却在充电）、来源未知或功率不可用 → unknown；
        /// 4. unknown 不累计任何一侧的 seconds/Wh。
        var batteryChannel: WindowTelemetryAggregator.BatteryChannel {
            guard let external = resolvedExternalConnected,
                  let info = batteryInfo, info.batteryPowerAvailable else { return .unknown }
            switch (external, powerSource.isCharging) {
            case (true, true):
                return .charge(info.batteryPower)
            case (false, false):
                return .discharge(info.batteryPower)
            case (true, false), (false, true):
                // 接电未充电（满电保持/优化充电暂停/80% 上限）与矛盾状态
                // 都不得进入任何一侧积分
                return .unknown
            }
        }
    }

    /// 一轮读取中关键字段的来源标注。IORegistry 没有硬件时间戳，
    /// 因此这里没有 sourceSampleAt 字段——App 读取时间不得冒充传感器时间。
    struct ReadingProvenance: Equatable {
        var systemLoadSource: TelemetrySource = .unavailable
        var systemLoadIsEstimated: Bool = true
        var batteryPowerSource: TelemetrySource = .unavailable
        /// 温度来源；nil 表示本轮温度不可读
        var temperatureSource: TelemetrySource?

        static let empty = ReadingProvenance()
    }

    /// 适配器额定信息在插拔之间基本不变；缓存可避免每秒重复遍历三类 IORegistry 服务。
    private let adapterCacheLock = NSLock()
    private var adapterCache: (value: AdapterInfo, checkedAt: Date)?
    private let adapterCacheTTL: TimeInterval = 30

    func readPowerSource() -> PowerSourceInfo? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [Any],
              !list.isEmpty
        else {
            return nil
        }

        let descriptions = list.compactMap {
            IOPSGetPowerSourceDescription(info, $0 as CFTypeRef)?.takeUnretainedValue() as? [String: Any]
        }
        guard let desc = descriptions.first(where: {
            ($0[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType
        }) ?? descriptions.first(where: {
            // 仅在缺失类型键的旧条目下回退，绝不把外接 UPS 冒充为本机内置电池。
            $0[kIOPSTypeKey] == nil
        }),
              let capacity = desc[kIOPSCurrentCapacityKey] as? Int,
              let maxCap = desc[kIOPSMaxCapacityKey] as? Int,
              let level = Self.normalizedBatteryLevel(capacity, maxCapacity: maxCap) else { return nil }

        let isCharging = desc[kIOPSIsChargingKey] as? Bool ?? false
        let powerSource = desc[kIOPSPowerSourceStateKey] as? String ?? ""
        let isPluggedIn = powerSource == kIOPSACPowerValue
        let timeRemaining = (isCharging
            ? desc[kIOPSTimeToFullChargeKey] as? Int
            : desc[kIOPSTimeToEmptyKey] as? Int) ?? -1
        // IOPM.h 的 kIOPMPSBatteryChargeStatusKey 定义为公开字串 "ChargeStatus"；
        // Swift module map 未暴露宏名，因此通过 IOPS 公共字典键读取。
        let chargeStatus = desc["ChargeStatus"] as? String

        return PowerSourceInfo(
            level: level,
            isCharging: isCharging,
            isPluggedIn: isPluggedIn,
            chargeStatus: chargeStatus,
            timeRemaining: timeRemaining,
            sourceStateAvailable: powerSource == kIOPSACPowerValue || powerSource == kIOPSBatteryPowerValue,
            chargingStateAvailable: desc[kIOPSIsChargingKey] is Bool
        )
    }

    /// 返回 nil 表示本轮 IOPS 读取失败：调用方必须保留上次状态，
    /// 不能把失败合成为 0%/离电污染插拔状态机。
    func readBatteryReading() -> BatteryReading? {
        guard let powerSource = readPowerSource() else { return nil }
        let (info, provenance) = readBatteryInfoWithProvenance(powerSource: powerSource)
        // readAt 在本轮 IOPS + IORegistry 全部读取完成后取得：
        // 它是「App 完成读取」的时刻，不是传感器采样时间（IORegistry 无硬件时间戳）。
        return BatteryReading(
            powerSource: powerSource,
            batteryInfo: info,
            provenance: info == nil ? .empty : provenance,
            readAt: Date()
        )
    }

    private func readBatteryInfoWithProvenance(powerSource: PowerSourceInfo?) -> (info: BatteryInfo?, provenance: ReadingProvenance) {
        var provenance = ReadingProvenance.empty
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return (nil, .empty) }
        defer { IOObjectRelease(service) }

        // macOS 27+：顶层 DesignCapacity 已移除，改放到 BatteryData 嵌套字典里
        // 新系统把温度等 pack 级数据移到了 AppleSmartBatteryPack/BatteryData；
        // 只匹配 AppleSmartBattery 会漏掉本机真实存在的传感器数据。
        let packService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBatteryPack"))
        defer { if packService != 0 { IOObjectRelease(packService) } }
        // 同一轮只把大型嵌套字典从 IORegistry 复制一次；旧实现每取一个字段都会
        // 再次跨 IOKit 边界创建整份 CFDictionary，是前台 1 秒轮询的主要分配热点。
        let batteryData = readDictionary(service, "BatteryData")
        let packBatteryData = readDictionary(packService, "BatteryData")
        let telemetryData = readDictionary(service, "PowerTelemetryData")

        let designCap = Self.firstValidCapacity([
            readInt(service, "DesignCapacity"),
            dictionaryInt(batteryData, key: "DesignCapacity"),
            dictionaryInt(packBatteryData, key: "DesignCapacity"),
        ])
        // 顶层 MaxCapacity 语义随系统版本变化：
        //   - 旧系统：mAh（>1000）
        //   - macOS 27+：健康度百分比（≤100）
        let maxCapRaw = readInt(service, "MaxCapacity")
        // 实际满充容量（mAh）：优先 BatteryData.FullChargeCapacity（macOS 27+），
        // 其次 FccComp1（部分旧系统），再退到旧版顶层 mAh 或百分比推算
        let fcc = Self.firstValidCapacity([
            dictionaryInt(batteryData, key: "FullChargeCapacity"),
            dictionaryInt(batteryData, key: "FccComp1"),
            dictionaryInt(packBatteryData, key: "FullChargeCapacity"),
            dictionaryInt(packBatteryData, key: "FccComp1"),
        ])
        let fullChargeCapInfo = Self.resolvedFullChargeCapacityInfo(fcc: fcc, rawMax: maxCapRaw, design: designCap)
        let actualMaxCap = fullChargeCapInfo.capacity
        let nominalCap = Self.firstValidCapacity([
            dictionaryInt(batteryData, key: "NominalChargeCapacity"),
            dictionaryInt(packBatteryData, key: "NominalChargeCapacity"),
            readInt(service, "NominalChargeCapacity"),
        ])

        let cycles = Self.firstValidCycleCount([
            readInt(service, "CycleCount"),
            dictionaryInt(packBatteryData, key: "CycleCount"),
        ])
        let designCycles = Self.firstValidCycleCount([
            readInt(service, "DesignCycleCount9C"),
            dictionaryInt(batteryData, key: "DesignCycleCount9C"),
            dictionaryInt(packBatteryData, key: "DesignCycleCount9C"),
        ])
        let voltage = Self.firstValidDouble([
            readDouble(service, "Voltage"),
            dictionaryDouble(batteryData, key: "Voltage"),
            dictionaryDouble(packBatteryData, key: "Voltage"),
        ], normalize: Self.normalizedBatteryVoltage)
        let amperageCandidates = [
            readDouble(service, "InstantAmperage"),
            readDouble(service, "Amperage"),
            dictionaryDouble(batteryData, key: "InstantAmperage"),
            dictionaryDouble(batteryData, key: "Amperage"),
            dictionaryDouble(packBatteryData, key: "InstantAmperage"),
            dictionaryDouble(packBatteryData, key: "Amperage"),
        ].compactMap { $0 }
        let amperage = amperageCandidates.first(where: {
            $0.isFinite && abs($0) <= 30_000
        }).map(Self.normalizedBatteryCurrent) ?? 0
        // 温度来源必须如实区分 SmartBattery 与 Pack 节点；IORegistry 无硬件时间戳，
        // sourceSampleAt 恒为 nil（质量模型层面强制）。
        let smartBatteryTemperatureCandidates: [Double?] = [
            readDouble(service, "Temperature"),
            dictionaryDouble(batteryData, key: "Temperature"),
        ]
        let packTemperatureCandidates: [Double?] = [
            readDouble(packService, "Temperature"),
            dictionaryDouble(packBatteryData, key: "Temperature"),
            dictionaryDouble(packBatteryData, key: "VirtualTemperature"),
        ]
        let resolvedTemp = Self.resolveTemperature(
            smartBatteryCandidates: smartBatteryTemperatureCandidates,
            packCandidates: packTemperatureCandidates
        )
        let temperature = resolvedTemp.value
        provenance.temperatureSource = resolvedTemp.source
        let isCharging = readOptionalBool(service, "IsCharging") ?? powerSource?.isCharging ?? false
        let externalConnected = readOptionalBool(service, "ExternalConnected") ?? powerSource?.isPluggedIn ?? false
        // IOPS 公共描述缺键时保持未知；不从 IORegistry 私有原因位回推状态。
        let chargeStatus = powerSource?.chargeStatus

        // 电池包功率必须区分「可信的有效 0W」与「没有读到功率」，不得用普通
        // Double=0 同时表达两者。来源选择（优先级/0 立即胜出/坏值跳过/V×I 兜底）
        // 见 BatteryPowerSelection（纯逻辑选择规则）。兼容哨兵 0 只允许进入
        // BatterySnapshot 兼容字段，不得进入质量模型或分钟积分。
        let batteryPowerResult = BatteryPowerSelection.resolve(
            directCandidates: [
                (dictionaryDouble(telemetryData, key: "BatteryPower"), .batteryPowerTelemetry),
                (dictionaryDouble(batteryData, key: "BatteryPower"), .batteryPowerTelemetry),
                (dictionaryDouble(packBatteryData, key: "BatteryPower"), .batteryPowerTelemetry),
            ],
            voltage: voltage,
            amperage: amperage
        )
        if batteryPowerResult.available {
            provenance.batteryPowerSource = batteryPowerResult.source
        }
        let batteryPower = batteryPowerResult.value
        let batteryPowerAvailable = batteryPowerResult.available

        // Apple Silicon 的 PowerTelemetryData 提供系统负载与适配器输入功率，单位 mW。
        // 旧实现把 batteryPower（充电时只是电池包净流入功率）标成“系统总功耗”，
        // 在接电且满电时会显示 0.x W，而机器真实负载通常仍有数瓦到十几瓦。
        let telemetrySystemLoad = Self.normalizedTelemetryMilliwatts(
            dictionaryDouble(telemetryData, key: "SystemLoad")
        )
        let telemetryInputPower = Self.normalizedInputMilliwatts(
            dictionaryDouble(telemetryData, key: "SystemPowerIn")
        )

        let legacySystemPower = Self.firstValidDouble([
            dictionaryDouble(batteryData, key: "SystemPower"),
        ], normalize: Self.normalizedTelemetryPower)
        let systemPower: Double
        let systemPowerAvailable: Bool
        let systemPowerIsEstimated: Bool
        if telemetrySystemLoad > 0 {
            systemPower = telemetrySystemLoad
            systemPowerAvailable = true
            systemPowerIsEstimated = false
            provenance.systemLoadSource = .telemetrySystemLoad
            provenance.systemLoadIsEstimated = false
        } else if legacySystemPower > 0 {
            systemPower = legacySystemPower
            systemPowerAvailable = true
            systemPowerIsEstimated = false
            provenance.systemLoadSource = .batteryDataSystemPower
            provenance.systemLoadIsEstimated = false
        } else if !externalConnected {
            // 离电时，电池包输出功率可作为整机负载的近似值（含转换损耗）；
            // 不再使用离电后可能残留上次接电数值的 BatteryData.AdapterPower。
            systemPower = batteryPower
            systemPowerAvailable = batteryPower > 0
            systemPowerIsEstimated = true
            if systemPowerAvailable {
                provenance.systemLoadSource = provenance.batteryPowerSource == .voltageCurrentDerived
                    ? .voltageCurrentDerived
                    : .batteryPowerTelemetry
            } else {
                provenance.systemLoadSource = .unavailable
            }
        } else {
            // 接电时不能用电池充电功率代替整机负载；宁可明确不可用，也不显示假精度。
            systemPower = 0
            systemPowerAvailable = false
            systemPowerIsEstimated = false
            provenance.systemLoadSource = .unavailable
        }

        let adapter = cachedAdapterInfo(isConnected: externalConnected)

        return (
            BatteryInfo(
                designCapacity: designCap,
                maxCapacity: actualMaxCap,
                cycleCount: cycles,
                voltage: voltage,
                instantAmperage: amperage,
                temperature: temperature,
                isCharging: isCharging,
                externalConnected: externalConnected,
                chargeStatus: chargeStatus,
                systemPower: systemPower,
                batteryPower: batteryPower,
                batteryPowerAvailable: batteryPowerAvailable,
                adapterInputPower: telemetryInputPower ?? 0,
                adapterInputPowerAvailable: telemetryInputPower != nil,
                systemPowerAvailable: systemPowerAvailable,
                systemPowerIsEstimated: systemPowerIsEstimated,
                adapterWatts: adapter.watts,
                adapterProtocol: adapter.protocolName,
                nominalCapacity: nominalCap,
                designCycleCount: designCycles,
                maxCapacityIsEstimated: fullChargeCapInfo.isEstimated
            ),
            provenance
        )
    }

    /// IORegistry 的 PowerTelemetryData 使用 mW；少数旧节点可能直接给 W。
    /// 统一为瓦特并拒绝无效/溢出哨兵值。
    static func normalizedTelemetryPower(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0 else { return 0 }
        let watts = raw > 250 ? raw / 1000.0 : raw
        guard watts > 0, watts < 500 else { return 0 }
        return watts
    }

    /// PowerTelemetryData 的单位由节点定义为 mW；显式换算避免小于 250mW 时被启发式误判为 W。
    static func normalizedTelemetryMilliwatts(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw > 0, raw < 500_000 else { return 0 }
        let watts = raw / 1_000
        return watts > 0 && watts < 500 ? watts : 0
    }

    /// Input telemetry has explicit availability; a reported zero is valid.
    static func normalizedInputMilliwatts(_ raw: Double?) -> Double? {
        guard let raw, raw.isFinite, raw >= 0, raw < 500_000 else { return nil }
        return raw / 1_000
    }

    /// 电池包直接功率允许正负号（充入/放出），对外统一返回绝对瓦数。
    static func normalizedBatteryPower(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, abs(raw) > 0, abs(raw) < 500_000 else { return 0 }
        let watts = abs(raw) / 1_000
        return watts > 0 && watts < 500 ? watts : 0
    }

    /// IORegistry Temperature/VirtualTemperature 使用百分之一摄氏度；兼容少数直接给 °C 的节点。
    /// 合法域 -20...100（与 v5 tAvg/tMax 远端校验一致）；冬季户外电池可达负温度，
    /// 不得用 raw > 0 当哨兵丢弃。0 兼任「不可读」哨兵（下游 >0.25 门槛丢弃），
    /// 真实 0°C 极罕见且不会改变趋势判断；与历史口径保持一致。
    static func normalizedBatteryTemperature(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw != 0 else { return 0 }
        let celsius = abs(raw) > 100 ? raw / 100 : raw
        return (celsius >= -20 && celsius <= 100) ? celsius : 0
    }

    /// IORegistry `Temperature` / `VirtualTemperature` 始终以百分之一摄氏度上报，
    /// 显式按 `raw / 100` 换算，避免 `100` (1.0°C) 或 `-100` (-1.0°C) 被启发式误判为直给 °C。
    static func normalizedIORegistryTemperature(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw != 0 else { return 0 }
        let celsius = raw / 100.0
        return (celsius >= -20 && celsius <= 100) ? celsius : 0
    }

    static func normalizedBatteryVoltage(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw >= 5_000, raw <= 30_000 else { return 0 }
        return raw
    }

    static func normalizedBatteryCurrent(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, abs(raw) <= 30_000 else { return 0 }
        return raw
    }

    static func normalizedBatteryLevel(_ capacity: Int, maxCapacity: Int) -> Double? {
        guard capacity >= 0, maxCapacity > 0 else { return nil }
        // Scale before dividing: IOPS 58/100 must stay 58, not 57.999999999999993.
        return min(100, Double(capacity) * 100 / Double(maxCapacity))
    }

    static func normalizedCapacity(_ raw: Int?) -> Int {
        guard let raw, raw > 0, raw <= 100_000 else { return 0 }
        return raw
    }

    static func normalizedCycleCount(_ raw: Int?) -> Int {
        guard let raw, raw >= 0, raw <= 10_000 else { return 0 }
        return raw
    }

    private static func firstValidCapacity(_ candidates: [Int?]) -> Int {
        for raw in candidates {
            let value = normalizedCapacity(raw)
            if value > 0 { return value }
        }
        return 0
    }

    private static func firstValidCycleCount(_ candidates: [Int?]) -> Int {
        for raw in candidates {
            let value = normalizedCycleCount(raw)
            if value > 0 { return value }
        }
        return 0
    }

    private static func firstValidDouble(
        _ candidates: [Double?],
        normalize: (Double?) -> Double
    ) -> Double {
        for raw in candidates {
            let value = normalize(raw)
            if value > 0 { return value }
        }
        return 0
    }

    /// 按既定来源优先级解析有效电池温度（允许 -20…100°C，含冬季负温；0 附近仍视作不可读哨兵）。
    static func resolveTemperature(
        smartBatteryCandidates: [Double?],
        packCandidates: [Double?]
    ) -> (value: Double, source: TelemetrySource?) {
        if let value = firstValidValue(
            smartBatteryCandidates,
            normalize: normalizedIORegistryTemperature,
            where: { abs($0) > 0.25 }
        ) {
            return (value, .smartBatteryTemperature)
        }
        if let value = firstValidValue(
            packCandidates,
            normalize: normalizedIORegistryTemperature,
            where: { abs($0) > 0.25 }
        ) {
            return (value, .smartBatteryPackTemperature)
        }
        return (0, nil)
    }

    /// 与 firstValidDouble 相同的候选顺序，但返回首个满足断言的有效值本身（允许负值等非正合法域）。
    private static func firstValidValue(
        _ candidates: [Double?],
        normalize: (Double?) -> Double,
        where isValid: (Double) -> Bool = { $0 > 0 }
    ) -> Double? {
        for raw in candidates {
            let value = normalize(raw)
            if isValid(value) { return value }
        }
        return nil
    }

    // MARK: - system_profiler 进程执行（供系统健康度后台读取）

    /// 跨线程安全收集子进程 stdout 的小盒子（Swift 6 严格并发下禁止在
    /// @Sendable 闭包里直接捕获局部 var）。
    private final class StdoutBox: @unchecked Sendable {
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

    /// 运行子进程并捕获 stdout，带超时与管道死锁保护：
    /// - 先并发读管道再等待退出——否则输出超过管道缓冲（64KB）时子进程
    ///   阻塞在 write、父进程死锁在 `waitUntilExit`；
    /// - 超时先 SIGTERM（宽限 2s）再 SIGKILL，防止 system_profiler 偶发挂起
    ///   在后台按 TTL 节奏累积成排不掉的僵尸调用。
    /// 只允许在 detached 工具线程调用；失败返回 nil。
    private static func runProcessCapturingStdout(
        path: String,
        arguments: [String],
        timeout: TimeInterval
    ) -> Data? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return nil
        }

        // 先并发读满管道，再等待退出（消除 write 阻塞死锁模式）
        let box = StdoutBox()
        let readQueue = DispatchQueue(label: "bb.process.stdout-read")
        let group = DispatchGroup()
        group.enter()
        readQueue.async {
            box.set(pipe.fileHandleForReading.readDataToEndOfFile())
            group.leave()
        }

        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
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

        let captured = box.get()
        guard !captured.isEmpty else { return nil }
        return captured
    }

    // MARK: - 电源适配器 / 充电协议

    /// 电源适配器信息（仅保留界面真实展示的额定功率与充电协议）
    struct AdapterInfo {
        let watts: Double           // 适配器额定功率 (W)
        let protocolName: String    // 充电协议: "USB-PD", "USB-PD 2.0", "USB-PD 3.0", "未知", "未连接"
    }

    /// 读取电源适配器/充电协议信息。
    /// Apple Silicon 上 AppleSmartBattery 节点携带 AdapterDetails 字典
    /// （含 Watts/AdapterVoltage/Current）和 FedDetails（PD 协议版本）。
    func readAdapterInfo() -> AdapterInfo {
        // 方式1: AppleSmartBattery（实测含 AdapterDetails 和 FedDetails；禁止扁平回退读取电池自身 Voltage/Amperage）
        let smartBattery = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        if smartBattery != 0 {
            defer { IOObjectRelease(smartBattery) }
            if let info = extractAdapterDetails(from: smartBattery, allowFlatFallback: false) {
                return info
            }
        }

        // 方式2: AppleTypeCPUPMU
        let pmuService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleTypeCPUPMU"))
        if pmuService != 0 {
            defer { IOObjectRelease(pmuService) }
            if let info = extractAdapterDetails(from: pmuService, allowFlatFallback: true) {
                return info
            }
        }

        // 方式3: AppleACAdapter
        let adapterService = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleACAdapter"))
        if adapterService != 0 {
            defer { IOObjectRelease(adapterService) }
            if let info = extractAdapterDetails(from: adapterService, allowFlatFallback: true) {
                return info
            }
        }

        // Fallback
        let ps = readPowerSource()
        return AdapterInfo(
            watts: 0,
            protocolName: ps?.isPluggedIn == true ? "未知" : "未连接"
        )
    }

    private func cachedAdapterInfo(isConnected: Bool) -> AdapterInfo {
        guard isConnected else {
            adapterCacheLock.lock()
            adapterCache = nil
            adapterCacheLock.unlock()
            return AdapterInfo(watts: 0, protocolName: "未连接")
        }

        adapterCacheLock.lock()
        let cached = adapterCache
        adapterCacheLock.unlock()
        if let cached {
            let age = Date().timeIntervalSince(cached.checkedAt)
            if age >= 0, age < adapterCacheTTL {
                return cached.value
            }
        }

        let refreshed = readAdapterInfo()
        adapterCacheLock.lock()
        adapterCache = (refreshed, Date())
        adapterCacheLock.unlock()
        return refreshed
    }

    private func extractAdapterDetails(from service: io_registry_entry_t, allowFlatFallback: Bool) -> AdapterInfo? {
        if let dict = IORegistryEntryCreateCFProperty(service, "AdapterDetails" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any] {
            let watts = extractDouble(from: dict, keys: ["Watts", "AdapterWatts", "RatedPower"]) ?? 0
            let hasVoltageOrCurrent = (extractDouble(from: dict, keys: ["AdapterVoltage", "Voltage", "Volts"]) ?? 0) > 0
                || (extractDouble(from: dict, keys: ["Current", "Amps", "Amperage"]) ?? 0) > 0

            if watts > 0 || hasVoltageOrCurrent {
                var protocolName = "USB-PD"
                if let fedDetails = IORegistryEntryCreateCFProperty(service, "FedDetails" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]],
                   let firstFed = fedDetails.first(where: { ($0["FedPdSpecRevision"] as? Int ?? 0) > 0 }),
                   let pdRev = firstFed["FedPdSpecRevision"] as? Int {
                    protocolName = pdRev >= 3 ? "USB-PD 3.0" : (pdRev >= 2 ? "USB-PD 2.0" : "USB-PD")
                }
                batteryReaderLogger.info("Adapter: watts=\(watts), protocol=\(protocolName, privacy: .public)")
                return AdapterInfo(watts: watts, protocolName: protocolName)
            }
            batteryReaderLogger.info("Adapter: AdapterDetails dict exists but all values are 0")
        } else {
            batteryReaderLogger.info("Adapter: AdapterDetails property not found")
        }

        guard allowFlatFallback else { return nil }

        let watts = readDouble(service, "Watts")
            ?? readDouble(service, "AdapterWatts")
            ?? Double(readInt(service, "Watts") ?? 0)
        if watts > 0 {
            batteryReaderLogger.info("Adapter(flat): watts=\(watts)")
            return AdapterInfo(watts: watts, protocolName: "未知")
        }
        return nil
    }

    /// 从字典中按候选键名抽取数值（兼容 Double/Int/NSNumber）。
    private func extractDouble(from dict: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let v = dict[key] as? Double { return v }
            if let v = dict[key] as? Int { return Double(v) }
            if let v = dict[key] as? NSNumber { return v.doubleValue }
        }
        return nil
    }

    static func resolvedFullChargeCapacityInfo(fcc: Int, rawMax: Int?, design: Int) -> (capacity: Int, isEstimated: Bool) {
        if normalizedCapacity(fcc) > 0 { return (fcc, false) }
        guard let rawMax else { return (0, false) }
        if rawMax > 1000 { return (normalizedCapacity(rawMax), false) }
        guard (1...100).contains(rawMax), normalizedCapacity(design) > 0 else { return (0, false) }
        let estimated = normalizedCapacity(design * rawMax / 100)
        return (estimated, estimated > 0)
    }

    static func resolvedFullChargeCapacity(fcc: Int, rawMax: Int?, design: Int) -> Int {
        resolvedFullChargeCapacityInfo(fcc: fcc, rawMax: rawMax, design: design).capacity
    }

    static func normalizedComponentPower(_ raw: Double?) -> Double {
        guard let raw, raw.isFinite, raw >= 0, raw < 500 else { return 0 }
        return raw
    }

    // MARK: - 系统电池健康（system_profiler 口径）

    /// 健康度进程内缓存：避免重复 spawn system_profiler；
    /// 刷新节奏（小时级 TTL / 唤醒后）由 PowerSampler 决定，不进入采样路径。
    /// 解析与口径选择纯函数见 BatteryHealthMetric。
    private let healthCacheLock = NSLock()
    private var cachedSystemHealth: SystemHealthReading?

    /// 后台读取系统健康度。耗时 1–3s，只允许在 detached 任务中调用，
    /// 绝不进入 5/15 秒采样路径。60 秒进程内缓存防止重复 spawn。
    func readSystemHealth() -> SystemHealthReading? {
        healthCacheLock.lock()
        let cached = cachedSystemHealth
        healthCacheLock.unlock()
        if let cached {
            let age = Date().timeIntervalSince(cached.readAt)
            if age >= 0, age < 60 {
                return cached
            }
        }

        guard let data = Self.runProcessCapturingStdout(
            path: "/usr/sbin/system_profiler",
            arguments: ["SPPowerDataType", "-json"],
            timeout: 15
        ) else {
            // 解析失败不缓存失败态：下次 TTL 到期重试；调用方负责回退口径。
            return nil
        }
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let percent = BatteryHealthMetric.systemProfilerHealthPercent(json: json) {
            let reading = SystemHealthReading(percent: percent, readAt: Date())
            healthCacheLock.lock()
            cachedSystemHealth = reading
            healthCacheLock.unlock()
            return reading
        }

        // 解析失败不缓存失败态：下次 TTL 到期重试；调用方负责回退口径。
        return nil
    }

    /// 打开系统电池设置
    func openBatterySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!
        NSWorkspace.shared.open(url)
    }

    // MARK: - IORegistry helpers

    private func readInt(_ entry: io_registry_entry_t, _ key: String) -> Int? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
    }

    private func readDouble(_ entry: io_registry_entry_t, _ key: String) -> Double? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Double
    }

    private func readOptionalBool(_ entry: io_registry_entry_t, _ key: String) -> Bool? {
        IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Bool
    }

    private func readDictionary(_ entry: io_registry_entry_t, _ key: String) -> [String: Any]? {
        guard entry != 0 else { return nil }
        return IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    private func dictionaryInt(_ dictionary: [String: Any]?, key: String) -> Int? {
        dictionary?[key] as? Int
    }

    private func dictionaryDouble(_ dictionary: [String: Any]?, key: String) -> Double? {
        dictionary?[key] as? Double
    }

}
