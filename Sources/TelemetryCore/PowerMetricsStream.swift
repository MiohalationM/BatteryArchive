import Foundation
import CoreFoundation

public struct ComponentPowerFrame: Equatable, Sendable {
    public var cpu: Double?
    public var gpu: Double?
    public var dram: Double?
    /// Receipt of the complete plist in Helper, not a hardware sample timestamp.
    public var receivedAt: Date
}

/// `powermetrics --format plist` emits NUL-separated XML documents (see its man page).
/// NUL precedes the next document, so publish as soon as the closing plist tag
/// parses successfully rather than waiting for the next sampling interval.
public struct PowerMetricsStream: Sendable {
    private var buffer = Data()
    private var discardingOversizedFrame = false
    private static let maximumFrameBytes = 1_048_576
    private static let closingTag = Data("</plist>".utf8)

    public init() {}

    public mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        discardingOversizedFrame = false
    }

    public mutating func consume(_ chunk: Data, receivedAt: Date) -> [ComponentPowerFrame] {
        var completed: [ComponentPowerFrame] = []
        for byte in chunk {
            if byte == 0 {
                if !discardingOversizedFrame, let frame = parseFrame(receivedAt: receivedAt) {
                    completed.append(frame)
                }
                buffer.removeAll(keepingCapacity: true)
                discardingOversizedFrame = false
            } else if !discardingOversizedFrame {
                if buffer.count < Self.maximumFrameBytes {
                    buffer.append(byte)
                    if byte == 0x3E, buffer.suffix(Self.closingTag.count) == Self.closingTag,
                       let frame = parseFrame(receivedAt: receivedAt) {
                        completed.append(frame)
                        buffer.removeAll(keepingCapacity: true)
                    }
                } else {
                    buffer.removeAll(keepingCapacity: false)
                    discardingOversizedFrame = true
                }
            }
        }
        return completed
    }

    private func parseFrame(receivedAt: Date) -> ComponentPowerFrame? {
        guard !buffer.isEmpty,
              let plist = try? PropertyListSerialization.propertyList(from: buffer, format: nil) as? [String: Any],
              let processor = plist["processor"] as? [String: Any] else { return nil }
        // Apple Silicon processor *_power values are mW, not W. A missing field
        // (including DRAM on systems without it) stays unavailable, never zero.
        func watts(_ key: String) -> Double? {
            guard let number = processor[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let value = number.doubleValue / 1_000
            return value.isFinite && value >= 0 && value < 500 ? value : nil
        }
        return ComponentPowerFrame(cpu: watts("cpu_power"), gpu: watts("gpu_power"),
                                   dram: watts("dram_power"), receivedAt: receivedAt)
    }
}
