import Foundation
import Testing
import TelemetryCore
@testable import BatteryArchive

@Suite struct HelperReliabilityTests {
    private let now = Date(timeIntervalSince1970: 1_793_200_000)

    // Synthetic fixtures matching the processor dictionary emitted by powermetrics.
    private func packet(_ processor: [String: Any]) throws -> Data {
        var data = try PropertyListSerialization.data(fromPropertyList: ["processor": processor], format: .xml, options: 0)
        data.append(0)
        return data
    }

    @Test func commitsOnlyCompleteFramesAcrossEveryByteBoundary() throws {
        var parser = PowerMetricsStream()
        let data = try packet(["cpu_power": 1200, "gpu_power": 0])
        let end = try #require(data.range(of: Data("</plist>".utf8))).upperBound
        for byte in data.prefix(end - 1) {
            #expect(parser.consume(Data([byte]), receivedAt: now).isEmpty)
        }
        let frames = parser.consume(Data([data[end - 1]]), receivedAt: now.addingTimeInterval(1))
        let frame = try #require(frames.first)
        #expect(frames.count == 1)
        #expect(frame.cpu == 1.2)
        #expect(frame.gpu == 0)
        #expect(frame.dram == nil)
        #expect(frame.receivedAt == now.addingTimeInterval(1))
        #expect(parser.consume(data.suffix(from: end), receivedAt: now.addingTimeInterval(10)).isEmpty)
    }

    @Test func missingFieldsDoNotAcquireOldValuesOrNewTimestamps() throws {
        var parser = PowerMetricsStream()
        let first = parser.consume(try packet(["cpu_power": 1000, "gpu_power": 2000]), receivedAt: now)
        #expect(first.first?.cpu == 1)
        #expect(first.first?.gpu == 2)
        let secondPacket = try packet(["cpu_power": 3000])
        let end = try #require(secondPacket.range(of: Data("</plist>".utf8))).lowerBound
        #expect(parser.consume(secondPacket.prefix(end), receivedAt: now.addingTimeInterval(9)).isEmpty)
        let second = parser.consume(secondPacket.suffix(from: end), receivedAt: now.addingTimeInterval(10))
        #expect(second.first?.cpu == 3)
        #expect(second.first?.gpu == nil)
        #expect(second.first?.receivedAt == now.addingTimeInterval(10))
    }

    @Test func restartDropsPartialFrame() throws {
        var parser = PowerMetricsStream()
        let partial = try packet(["cpu_power": 4000, "gpu_power": 2000])
        let end = try #require(partial.range(of: Data("</plist>".utf8))).lowerBound
        #expect(parser.consume(partial.prefix(end), receivedAt: now).isEmpty)
        parser.reset()
        let frames = parser.consume(try packet(["gpu_power": 0]), receivedAt: now)
        #expect(frames.count == 1)
        #expect(frames.first?.cpu == nil)
        #expect(frames.first?.gpu == 0)
    }

    @Test func realCaptureFramingDoesNotRequireTrailingNUL() throws {
        // macOS 27.0.1 live capture: two XML plists, one separating NUL, no final NUL.
        var data = try packet(["cpu_power": 5987.4, "gpu_power": 1013.22])
        data.append(try packet(["cpu_power": 2297.91, "gpu_power": 1020.42]).dropLast())
        var parser = PowerMetricsStream()
        let frames = parser.consume(data, receivedAt: now)
        #expect(frames.count == 2)
        #expect(abs(try #require(frames.first?.cpu) - 5.9874) < 0.000001)
        #expect(abs(try #require(frames.last?.gpu) - 1.02042) < 0.000001)
        #expect(frames.allSatisfy { $0.dram == nil })
    }

    @Test func multipleFramesAndMalformedPacketsStayIsolated() throws {
        var parser = PowerMetricsStream()
        var data = try packet(["cpu_power": 1000, "dram_power": 250])
        data.append(Data("not a plist\0\0".utf8))
        data.append(try packet(["gpu_power": 0]))
        let frames = parser.consume(data, receivedAt: now)
        #expect(frames.count == 2)
        #expect(frames.first?.dram == 0.25)
        #expect(frames.last?.cpu == nil)
        #expect(frames.last?.gpu == 0)
        #expect(frames.last?.dram == nil)
    }

    @Test func malformedValuesAreUnavailableNotZero() throws {
        var parser = PowerMetricsStream()
        let values: [Any] = [-1, 500_000, Double.infinity, Double.nan, true, "1000"]
        for value in values {
            let frames = parser.consume(try packet(["cpu_power": value, "gpu_power": 0]), receivedAt: now)
            #expect(frames.count == 1)
            #expect(frames.first?.cpu == nil)
            #expect(frames.first?.gpu == 0)
        }
        let empty = parser.consume(try packet([:]), receivedAt: now)
        #expect(empty.count == 1)
        #expect(empty.first?.cpu == nil)
    }

    @Test func oversizedFrameRecoversOnlyAtItsTerminator() throws {
        var parser = PowerMetricsStream()
        #expect(parser.consume(Data(repeating: 65, count: 1_048_577), receivedAt: now).isEmpty)
        let valid = try packet(["cpu_power": 1000])
        #expect(parser.consume(valid, receivedAt: now).isEmpty)
        #expect(parser.consume(valid, receivedAt: now).first?.cpu == 1)
    }

    @Test func partialInstallationNeverAppearsCurrent() {
        #expect(HelperInstaller.installedState(binaryExists: false, plistExists: false, needsUpdate: false) == .notInstalled)
        #expect(HelperInstaller.installedState(binaryExists: false, plistExists: true, needsUpdate: false) == .needsUpdate)
        #expect(HelperInstaller.installedState(binaryExists: true, plistExists: false, needsUpdate: false) == .needsUpdate)
        #expect(HelperInstaller.installedState(binaryExists: true, plistExists: true, needsUpdate: true) == .needsUpdate)
        #expect(HelperInstaller.installedState(binaryExists: true, plistExists: true, needsUpdate: false) == .current)
    }

    @Test func appUpgradeRequiresRebindingEvenWhenHelperUnchanged() {
        #expect(HelperInstaller.needsUpdate(installedHash: "AA", bundledHash: "aa", clientHash: "new", authorizedHash: "old"))
        #expect(HelperInstaller.needsUpdate(installedHash: "aa", bundledHash: "aa", clientHash: "new", authorizedHash: nil))
        #expect(!HelperInstaller.needsUpdate(installedHash: "AA", bundledHash: "aa", clientHash: "BB", authorizedHash: "bb"))
    }

    @Test func timeoutCannotBeOverwrittenByLateReply() async throws {
        let pending = HelperReply<Int>()
        do {
            _ = try await pending.value(timeout: 0.01) { _ in }
            Issue.record("expected timeout")
        } catch { #expect(error as? HelperClientError == .timeout) }
        pending.resolve(.success(42))
        do {
            _ = try await pending.value(timeout: 0.01) { _ in }
            Issue.record("late result replaced timeout")
        } catch { #expect(error as? HelperClientError == .timeout) }
    }

    @Test func cancellationBeforeRegistrationAndDuplicateCallbacksAreSafe() async throws {
        let cancelled = HelperReply<Int>()
        cancelled.resolve(.failure(.cancelled))
        do {
            _ = try await cancelled.value(timeout: 1) { _ in Issue.record("cancelled request was started") }
            Issue.record("expected cancellation")
        } catch { #expect(error as? HelperClientError == .cancelled) }
        let pending = HelperReply<Int>()
        let value = try await pending.value(timeout: 1) {
            $0.resolve(.success(1))
            $0.resolve(.failure(.disconnected))
            $0.resolve(.success(2))
        }
        #expect(value == 1)
    }

    @Test func cancellationWhileWaitingWinsOverLateSuccess() async throws {
        let pending = HelperReply<Int>()
        let started = HelperReply<Bool>()
        let task = Task { try await pending.value(timeout: 1) { _ in started.resolve(.success(true)) } }
        _ = try await started.value(timeout: 1) { _ in }
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected cancellation")
        } catch { #expect(error as? HelperClientError == .cancelled) }
        pending.resolve(.success(42))
    }

    @Test func connectionErrorCompletesWithoutWaitingForTimeout() async throws {
        let pending = HelperReply<Int>()
        do {
            _ = try await pending.value(timeout: 1) { $0.resolve(.failure(.disconnected)) }
            Issue.record("expected connection error")
        } catch { #expect(error as? HelperClientError == .disconnected) }
    }

    @Test func componentReplyDistinguishesUnavailableFromZero() throws {
        let sample = try #require(ComponentPower(reply: ["protocolVersion": "6.0", "cpu": 0,
                                                        "gpu": -1, "receivedAt": now.timeIntervalSince1970]))
        #expect(sample.cpu == 0)
        #expect(sample.gpu == nil)
        #expect(sample.dram == nil)
        #expect(ComponentPower(reply: ["cpu": 1, "available": true]) == nil)
        #expect(ComponentPower(reply: ["protocolVersion": "6.0"])?.receivedAt == .distantPast)
        #expect(ComponentPower(reply: ["protocolVersion": "6.0", "cpu": 1]) == nil)
        #expect(ComponentPower(reply: ["protocolVersion": "6.0", "receivedAt": true]) == nil)
        #expect(ComponentPower(reply: ["protocolVersion": "6.0", "receivedAt": Double.nan]) == nil)
        #expect(ComponentPower(reply: ["protocolVersion": "6.0", "cpu": true,
                                      "receivedAt": now.timeIntervalSince1970])?.cpu == nil)
    }

    @Test func manualInstallerUsesTheSameVerifiedStagingProgram() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let script = try String(contentsOf: root.appendingPathComponent("scripts/install-helper.sh"), encoding: .utf8)
        let start = try #require(script.range(of: "ROOT_INSTALL_SCRIPT=$(cat <<'SH'\n"))
        let end = try #require(script.range(of: "\nSH\n", range: start.upperBound..<script.endIndex))
        #expect(String(script[start.upperBound..<end.lowerBound]) == HelperInstaller.installShellScript)
    }

    @Test func legacyHelperDetectionAndCleanupContract() {
        #expect(HelperInstaller.legacyHelperIdentifier == "com.batterybar.helper")

        #expect(HelperInstaller.hasLegacyHelperInstalled(binaryExists: false, plistExists: false) == false)
        #expect(HelperInstaller.hasLegacyHelperInstalled(binaryExists: true, plistExists: false) == true)
        #expect(HelperInstaller.hasLegacyHelperInstalled(binaryExists: false, plistExists: true) == true)
        #expect(HelperInstaller.hasLegacyHelperInstalled(binaryExists: true, plistExists: true) == true)

        #expect(HelperInstaller.needsUninstall(binaryExists: false, plistExists: false, legacyBinaryExists: false, legacyPlistExists: false) == false)
        #expect(HelperInstaller.needsUninstall(binaryExists: true, plistExists: false, legacyBinaryExists: false, legacyPlistExists: false) == true)
        #expect(HelperInstaller.needsUninstall(binaryExists: false, plistExists: true, legacyBinaryExists: false, legacyPlistExists: false) == true)
        #expect(HelperInstaller.needsUninstall(binaryExists: false, plistExists: false, legacyBinaryExists: true, legacyPlistExists: false) == true)
        #expect(HelperInstaller.needsUninstall(binaryExists: false, plistExists: false, legacyBinaryExists: false, legacyPlistExists: true) == true)

        #expect(HelperInstaller.installShellScript.contains("/bin/launchctl bootout system/com.batterybar.helper 2>/dev/null || true"))
        #expect(HelperInstaller.installShellScript.contains("/bin/rm -f /Library/PrivilegedHelperTools/com.batterybar.helper /Library/LaunchDaemons/com.batterybar.helper.plist"))

        let uninstallScript = HelperInstaller.uninstallAppleScript
        #expect(uninstallScript.components(separatedBy: "with administrator privileges").count == 2)
        for index in 1...7 {
            #expect(uninstallScript.contains("item \(index) of argv"))
        }
    }

    @Test func verifiedStagedBytesSurviveSourceReplacement() throws {
        try runStagingTest(validHash: true)
    }

    @Test func invalidPayloadNeverReplacesDestination() throws {
        try runStagingTest(validHash: false)
    }

    @Test func sourceReplacedBeforeCopyIsRejected() throws {
        try runStagingTest(validHash: true, replaceBeforeCopy: true)
    }

    @Test func symlinkPayloadIsRejected() throws {
        try runStagingTest(validHash: true, symlink: true)
    }

    private func runStagingTest(validHash: Bool, replaceBeforeCopy: Bool = false, symlink: Bool = false) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Helper staging ' \(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("source")
        let destination = dir.appendingPathComponent("installed")
        // Copy a signed system executable as inert bytes; never execute it or launch a service.
        try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: source)
        let original = try Data(contentsOf: source)
        try Data("previous".utf8).write(to: destination)
        let hash = try #require(HelperInstaller.sha256Hex(at: source.path))
        if replaceBeforeCopy { try Data("changed before root copy".utf8).write(to: source) }
        if symlink {
            try FileManager.default.removeItem(at: source)
            try FileManager.default.createSymbolicLink(atPath: source.path, withDestinationPath: "/usr/bin/true")
        }
        let shouldInstall = validHash && !replaceBeforeCopy && !symlink
        let plist = "<?xml version=\"1.0\"?><plist version=\"1.0\"><dict><key>Label</key><string>fixture</string></dict></plist>"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", HelperInstaller.payloadStagingScript + "\n" +
                             "/usr/bin/printf changed > \"$source\"\n/bin/cp \"$stage/helper\" \"$destination\"",
                             "--", source.path, destination.path, dir.appendingPathComponent("daemon.plist").path,
                             plist, validHash ? hash : String(repeating: "0", count: 64)]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect((process.terminationStatus == 0) == shouldInstall)
        #expect(try Data(contentsOf: destination) == (shouldInstall ? original : Data("previous".utf8)))
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path).allSatisfy { !$0.hasPrefix(".batteryarchive.") })
    }
}
