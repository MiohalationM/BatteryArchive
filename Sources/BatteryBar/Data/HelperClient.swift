import Foundation
import CoreFoundation

@objc protocol HelperProtocol {
    @objc optional func getComponentPower(withReply reply: @escaping (NSDictionary) -> Void)
    @objc optional func getVersion(withReply reply: @escaping (String) -> Void)
}

enum HelperClientError: Error, Equatable, Sendable, LocalizedError {
    case timeout, disconnected, cancelled, needsUpdate, invalidSample

    var errorDescription: String? {
        switch self {
        case .timeout: "后台服务响应超时"
        case .disconnected: "后台服务连接已断开"
        case .cancelled: "采样请求已取消"
        case .needsUpdate: "后台服务或客户端授权需要更新"
        case .invalidSample: "后台服务返回了无效采样"
        }
    }
}

/// One request has exactly one outcome, including cancellation before registration.
final class HelperReply<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var result: Result<Value, HelperClientError>?
    private var continuation: CheckedContinuation<Value, any Error>?
    private var timeoutItem: DispatchWorkItem?

    func resolve(_ result: Result<Value, HelperClientError>) {
        lock.lock()
        guard self.result == nil else { lock.unlock(); return }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        let workItem = timeoutItem
        self.timeoutItem = nil
        lock.unlock()
        workItem?.cancel()
        continuation?.resume(with: result.mapError { $0 as any Error })
    }

    private func register(_ continuation: CheckedContinuation<Value, any Error>) -> Bool {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result.mapError { $0 as any Error })
            return false
        } else {
            self.continuation = continuation
            lock.unlock()
            return true
        }
    }

    private func installTimeout(_ item: DispatchWorkItem) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard result == nil else { return false }
        timeoutItem = item
        return true
    }

    func value(timeout: TimeInterval, start: (HelperReply<Value>) -> Void) async throws -> Value {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard register(continuation) else { return }
                let workItem = DispatchWorkItem { [weak self] in
                    self?.resolve(.failure(.timeout))
                }
                if installTimeout(workItem) {
                    DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: workItem)
                }
                if !Task.isCancelled { start(self) }
            }
        } onCancel: {
            self.resolve(.failure(.cancelled))
        }
    }
}

/// Requests use their own connections, so cancellation/invalidation cannot affect a
/// later generation. At the ten-second cadence this avoids a shared connection cache.
final class HelperClient: @unchecked Sendable {
    static let requiredVersion = "6.0"

    private func connection() -> NSXPCConnection {
        let connection = NSXPCConnection(machServiceName: HelperInstaller.helperIdentifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HelperProtocol.self)
        return connection
    }

    func checkVersion() async throws {
        guard !Task.isCancelled else { throw HelperClientError.cancelled }
        let connection = connection()
        let reply = HelperReply<String>()
        connection.invalidationHandler = { reply.resolve(.failure(.disconnected)) }
        connection.interruptionHandler = { reply.resolve(.failure(.disconnected)) }
        connection.resume()
        defer { connection.invalidate() }
        let version = try await reply.value(timeout: 2) { pending in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                pending.resolve(.failure(.disconnected))
            }) as? HelperProtocol, let getVersion = proxy.getVersion else {
                pending.resolve(.failure(.needsUpdate))
                return
            }
            getVersion { pending.resolve(.success($0)) }
        }
        guard version == Self.requiredVersion else { throw HelperClientError.needsUpdate }
    }

    func readComponentPower() async throws -> ComponentPower {
        guard !Task.isCancelled else { throw HelperClientError.cancelled }
        let connection = connection()
        let reply = HelperReply<ComponentPower>()
        connection.invalidationHandler = { reply.resolve(.failure(.disconnected)) }
        connection.interruptionHandler = { reply.resolve(.failure(.disconnected)) }
        connection.resume()
        defer { connection.invalidate() }
        return try await reply.value(timeout: 3) { pending in
            guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                pending.resolve(.failure(.disconnected))
            }) as? HelperProtocol, let getComponentPower = proxy.getComponentPower else {
                pending.resolve(.failure(.needsUpdate))
                return
            }
            getComponentPower { dict in
                guard dict["protocolVersion"] as? String == Self.requiredVersion else {
                    pending.resolve(.failure(.needsUpdate))
                    return
                }
                guard let sample = ComponentPower(reply: dict) else {
                    pending.resolve(.failure(.invalidSample))
                    return
                }
                pending.resolve(.success(sample))
            }
        }
    }
}

struct ComponentPower: Sendable, Equatable {
    var cpu: Double?
    var gpu: Double?
    var dram: Double?
    /// Helper receipt time, not a sensor timestamp.
    var receivedAt: Date

    init?(reply: NSDictionary) {
        guard reply["protocolVersion"] as? String == HelperClient.requiredVersion else { return nil }
        func power(_ key: String) -> Double? {
            guard let number = reply[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue
            guard value.isFinite, value >= 0, value < 500 else { return nil }
            return value
        }
        cpu = power("cpu")
        gpu = power("gpu")
        dram = power("dram")
        guard let rawTime = reply["receivedAt"] else {
            // A newly started Helper has no complete frame yet.
            guard cpu == nil, gpu == nil, dram == nil else { return nil }
            receivedAt = .distantPast
            return
        }
        guard let number = rawTime as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue > 0 else { return nil }
        let time = number.doubleValue
        receivedAt = Date(timeIntervalSince1970: time)
    }
}
