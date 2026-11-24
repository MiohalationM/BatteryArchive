import Foundation
import Security
import TelemetryCore

/// XPC 协议
@objc protocol HelperProtocol {
    // 读取 CPU/GPU/DRAM 功率（返回最近一次 powermetrics 采样缓存）
    // reply 标注 @Sendable：XPC 回调由 libxpc 在任意线程调用
    func getComponentPower(withReply reply: @escaping @Sendable (NSDictionary) -> Void)
    // 返回 helper 版本号（用于检测是否需要更新）
    func getVersion(withReply reply: @escaping (String) -> Void)
}

/// Minimal privileged sampler. Mutable process and frame state belongs to powerQueue.
class HelperTool: NSObject, NSXPCListenerDelegate, @unchecked Sendable {
    let listener: NSXPCListener

    /// powermetrics 进程状态只在 powerQueue（串行）上访问
    private let powerQueue = DispatchQueue(label: "com.batteryarchive.helper.powermetrics")
    private var metricsProcess: Process?
    private var metricsPipe: Pipe?
    private var stream = PowerMetricsStream()
    private var latestFrame: ComponentPowerFrame?
    private var processGeneration: UInt64 = 0
    /// 单调运行时间（秒）：免疫 NTP / 墙钟跳变导致的空闲计时或冷却期错乱。
    private var lastRequestUptime: TimeInterval = ProcessInfo.processInfo.systemUptime
    private let idleTimeout: TimeInterval = 60
    private var idleTimer: DispatchSourceTimer?
    // 启动失败退避：参数无效/二进制异常时避免 1s 重启风暴
    private var processStartedUptime: TimeInterval = 0
    private var failedStarts = 0
    private var cooldownUntilUptime: TimeInterval = 0
    private let processIdleTimeout: TimeInterval = 120

    override init() {
        self.listener = NSXPCListener(machServiceName: "com.batteryarchive.helper")
        super.init()
        self.listener.delegate = self
        powerQueue.async { [self] in
            scheduleIdleCheckLocked()
        }
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        guard isCallerAllowed(connection) else {
            // 直接拒绝未授权连接，不为其分配已恢复但无导出对象的空连接。
            return false
        }
        connection.exportedInterface = NSXPCInterface(with: HelperProtocol.self)
        connection.exportedObject = self
        connection.resume()
        return true
    }

    /// 调用方校验：pid 反查 SecCode，要求签名有效、bundle id 匹配，并且 CDHash
    /// 等于安装时写入 launchd 环境的主程序 CDHash。即便当前使用 ad-hoc 签名，
    /// 其他进程也不能仅靠伪造 bundle id 调用现有 root Helper。
    private func isCallerAllowed(_ connection: NSXPCConnection) -> Bool {
        let pid = connection.processIdentifier
        var code: SecCode?
        let attrs = [kSecGuestAttributePid: pid] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attrs, [], &code) == errSecSuccess,
              let code else {
            return false
        }
        // 有效签名：代码与其自身 designated requirement（ad-hoc 即 cdhash）一致，未被篡改
        guard SecCodeCheckValidity(code, [], nil) == errSecSuccess else {
            return false
        }
        return HelperAuthorization.allows(
            identifier: codeIdentifier(code),
            actualCDHash: codeDirectoryHash(code),
            expectedCDHash: ProcessInfo.processInfo.environment["BATTERYARCHIVE_AUTHORIZED_CLIENT_CDHASH"]
        )
    }

    private func codeIdentifier(_ code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any] else { return nil }
        return info[kSecCodeInfoIdentifier as String] as? String
    }

    private func codeDirectoryHash(_ code: SecCode) -> String? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess,
              let staticCode else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

extension HelperTool: HelperProtocol {
    func getComponentPower(withReply reply: @escaping @Sendable (NSDictionary) -> Void) {
        powerQueue.async { [self] in
            lastRequestUptime = ProcessInfo.processInfo.systemUptime
            // 懒启动：进程不在跑（未启动/已退出/空闲退出）则启动
            if metricsProcess == nil {
                startPowermetricsLocked()
            }
            var value: [String: Any] = ["protocolVersion": "6.0"]
            if let frame = latestFrame {
                value["cpu"] = frame.cpu
                value["gpu"] = frame.gpu
                value["dram"] = frame.dram
                value["receivedAt"] = frame.receivedAt.timeIntervalSince1970
            }
            reply(value as NSDictionary)
        }
    }

    func getVersion(withReply reply: @escaping (String) -> Void) {
        powerQueue.async { [self] in
            lastRequestUptime = ProcessInfo.processInfo.systemUptime
        }
        reply("6.0")
    }

    // MARK: - powermetrics 流式进程管理（以下方法均在 powerQueue 上执行）

    /// 采样器列表：Apple Silicon 上 `cpu_power` 帧已自带 DRAM 功耗字段，
    /// macOS 14–27 均不存在独立的 `dram` 采样器（传入无效采样器会导致 powermetrics 直接退出）。
    private func powermetricsArguments() -> [String] {
        return ["--samplers", "cpu_power,gpu_power", "-i", "10000", "--format", "plist", "-b", "0"]
    }

    private func startPowermetricsLocked() {
        // 连续快速失败后的冷却期内不再尝试
        let nowUptime = ProcessInfo.processInfo.systemUptime
        guard nowUptime >= cooldownUntilUptime else { return }
        processGeneration &+= 1
        let generation = processGeneration
        stream.reset()
        latestFrame = nil
        metricsPipe?.fileHandleForReading.readabilityHandler = nil
        metricsPipe = nil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/powermetrics")
        process.arguments = powermetricsArguments()
        var environment = ProcessInfo.processInfo.environment
        environment["LANG"] = "C"
        environment["LC_ALL"] = "C"
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        // 意外退出：仍在活跃期则自动重启（launchd 不管理子进程）；
        // 存活 <10s 视为启动失败，连续 3 次进入 60s 冷却（防重启风暴）
        process.terminationHandler = { [weak self] _ in
            guard let self else { return }
            self.powerQueue.async {
                guard self.processGeneration == generation else { return }
                self.processGeneration &+= 1
                let restartGeneration = self.processGeneration
                self.latestFrame = nil
                self.stream.reset()
                self.metricsPipe?.fileHandleForReading.readabilityHandler = nil
                self.metricsPipe = nil
                self.metricsProcess = nil
                let exitedAt = ProcessInfo.processInfo.systemUptime
                let uptime = exitedAt - self.processStartedUptime
                if uptime < 10 {
                    self.failedStarts += 1
                    if self.failedStarts >= 3 {
                        self.cooldownUntilUptime = exitedAt + 60
                        self.failedStarts = 0
                        return
                    }
                } else {
                    self.failedStarts = 0
                }
                if (exitedAt - self.lastRequestUptime) < self.idleTimeout,
                   exitedAt >= self.cooldownUntilUptime {
                    self.powerQueue.asyncAfter(deadline: .now() + 1.0) {
                        let checkUptime = ProcessInfo.processInfo.systemUptime
                        if self.processGeneration == restartGeneration, self.metricsProcess == nil,
                           (checkUptime - self.lastRequestUptime) < self.idleTimeout,
                           checkUptime >= self.cooldownUntilUptime {
                            self.startPowermetricsLocked()
                        }
                    }
                }
            }
        }

        // 逐段读取 stdout，按 NUL 分隔的完整 plist 提交（readabilityHandler 在系统 IO 线程，
        // 统一调度回 powerQueue 保证状态串行）
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else {
                handle.readabilityHandler = nil
                return
            }
            guard let self else { return }
            self.powerQueue.async {
                guard self.processGeneration == generation, self.metricsProcess != nil else { return }
                self.consumeOutputLocked(chunk)
            }
        }

        do {
            try process.run()
            processStartedUptime = ProcessInfo.processInfo.systemUptime
            metricsPipe = pipe
            metricsProcess = process
        } catch {
            // 启动失败：保持 metricsProcess 为 nil，计入退避
            pipe.fileHandleForReading.readabilityHandler = nil
            failedStarts += 1
            if failedStarts >= 3 {
                cooldownUntilUptime = ProcessInfo.processInfo.systemUptime + 60
                failedStarts = 0
            }
        }
    }

    private func consumeOutputLocked(_ chunk: Data) {
        for frame in stream.consume(chunk, receivedAt: Date()) {
            latestFrame = frame
        }
    }

    /// 空闲检查：app 关闭或用户关闭开关后停止拉取 → 60s 无请求终止 powermetrics，
    /// root 子进程不再常驻烧电。
    private func scheduleIdleCheckLocked() {
        let timer = DispatchSource.makeTimerSource(queue: powerQueue)
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [self] in
            let idleFor = ProcessInfo.processInfo.systemUptime - lastRequestUptime
            if let process = metricsProcess, idleFor > idleTimeout {
                processGeneration &+= 1
                stream.reset()
                latestFrame = nil
                metricsPipe?.fileHandleForReading.readabilityHandler = nil
                metricsPipe = nil
                process.terminationHandler = nil  // 主动退出不触发重启
                metricsProcess = nil
                process.terminate()
                // 等待下个空闲周期再退出 Helper，避免与刚发送 SIGTERM 的 powermetrics 竞争导致孤儿进程。
                return
            }
            // MachServices 会在下次 XPC 连接时重新拉起进程。Helper 本身不再常驻；
            // 这只终止当前按需实例，不卸载 launchd job。
            if metricsProcess == nil, idleFor > processIdleTimeout {
                exit(EXIT_SUCCESS)
            }
        }
        timer.resume()
        idleTimer = timer
    }

}

// 启动 helper，等待 XPC 调用
let helper = HelperTool()
helper.listener.resume()
RunLoop.main.run()
