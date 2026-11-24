import Foundation
import Security
import CryptoKit
import os

private let helperInstallerLogger = Logger(subsystem: "com.batteryarchive", category: "HelperInstaller")

/// Disk/signature checks and explicit privileged operations. No sampling or XPC.
struct HelperInstaller: Sendable {
    static let helperIdentifier = "com.batteryarchive.helper"

    func installedState() -> InstalledHelperState {
        Self.installedState(
            binaryExists: FileManager.default.fileExists(atPath: "/Library/PrivilegedHelperTools/\(Self.helperIdentifier)"),
            plistExists: FileManager.default.fileExists(atPath: "/Library/LaunchDaemons/\(Self.helperIdentifier).plist"),
            needsUpdate: dormantInstalledHelperNeedsUpdate()
        )
    }

    static func installedState(binaryExists: Bool, plistExists: Bool,
                               needsUpdate: @autoclosure () -> Bool) -> InstalledHelperState {
        guard binaryExists || plistExists else { return .notInstalled }
        guard binaryExists && plistExists else { return .needsUpdate }
        return needsUpdate() ? .needsUpdate : .current
    }

    /// 安装 helper（首次需要管理员密码，app 内自动触发）
    /// 如果已安装但版本旧，也会触发重新安装；`force == true` 时即便磁盘文件一致也重新 bootstrap launchd。
    @discardableResult
    func installHelperIfNeeded(force: Bool = false) -> Bool {
        // 已安装且版本匹配，无需操作
        if !force, installedState() == .current { return true }

        let helperPath: String
        if let bundledPath = validatedBundledHelperPath() {
            helperPath = bundledPath
        } else {
#if DEBUG
            if let envPath = ProcessInfo.processInfo.environment["BATTERYARCHIVE_HELPER_PATH"],
               FileManager.default.fileExists(atPath: envPath) {
                // 仅 Debug 裸二进制开发使用；Release 构建绝不接受环境变量提供的 root payload。
                helperPath = envPath
            } else {
                helperInstallerLogger.error("Helper binary not found in app bundle. Ensure scripts/build-app.sh was used.")
                return false
            }
#else
            helperInstallerLogger.error("Helper binary not found in app bundle. Ensure scripts/build-app.sh was used.")
            return false
#endif
        }
        return installHelper(from: helperPath)
    }

    /// 只接受当前已签名 App Bundle 内、解析符号链接后仍位于 Resources 下的 Helper。
    /// 这既阻止 Release 环境变量替换 payload，也避免 bundle 内符号链接逃逸。
    private func validatedBundledHelperPath() -> String? {
        guard let resourceURL = Bundle.main.resourceURL?.resolvingSymlinksInPath(),
              let rawURL = Bundle.main.url(forResource: "BatteryArchiveHelper", withExtension: nil)
        else { return nil }
        let helperURL = rawURL.resolvingSymlinksInPath()
        let resourcePrefix = resourceURL.path.hasSuffix("/") ? resourceURL.path : resourceURL.path + "/"
        guard helperURL.path.hasPrefix(resourcePrefix),
              FileManager.default.isExecutableFile(atPath: helperURL.path),
              staticCodeIsValid(at: Bundle.main.bundleURL),
              staticCodeIsValid(at: helperURL)
        else {
            helperInstallerLogger.error("Rejecting untrusted bundled Helper")
            return nil
        }
        return helperURL.path
    }

    private func staticCodeIsValid(at url: URL) -> Bool {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return false }
        return SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate), nil) == errSecSuccess
    }

    /// Helper 关闭时比较磁盘代码签名哈希和客户端绑定，不建立 XPC 连接、不触发 launchd。
    /// 用于提示遗留版本需要更新，同时保持“默认关闭 = 零 Helper 调用”。
    private func dormantInstalledHelperNeedsUpdate() -> Bool {
        let installedURL = URL(fileURLWithPath: "/Library/PrivilegedHelperTools/com.batteryarchive.helper")
        guard let bundledPath = validatedBundledHelperPath(),
              staticCodeIsValid(at: installedURL),
              let installedHash = staticCodeCDHash(at: installedURL),
              let bundledHash = staticCodeCDHash(at: URL(fileURLWithPath: bundledPath)),
              let clientHash = currentExecutableCDHash(),
              let data = try? Data(contentsOf: URL(fileURLWithPath: "/Library/LaunchDaemons/\(Self.helperIdentifier).plist")),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let env = plist["EnvironmentVariables"] as? [String: String]
        else { return true }
        return Self.needsUpdate(installedHash: installedHash, bundledHash: bundledHash,
                                clientHash: clientHash, authorizedHash: env["BATTERYARCHIVE_AUTHORIZED_CLIENT_CDHASH"])
    }

    static func needsUpdate(installedHash: String, bundledHash: String, clientHash: String, authorizedHash: String?) -> Bool {
        installedHash.lowercased() != bundledHash.lowercased()
            || clientHash.isEmpty || authorizedHash?.lowercased() != clientHash.lowercased()
    }

    // The hash is checked on the root-owned copy that will actually be installed.
    // This prefix is also exercised in temporary directories without elevation.
    static let payloadStagingScript = """
    set -eu
    source=$1; destination=$2; plistDestination=$3; plistContents=$4; expected=$5
    umask 077
    stage=$(/usr/bin/mktemp -d "$(/usr/bin/dirname "$destination")/.batteryarchive.XXXXXXXX")
    trap '/bin/rm -rf "$stage"' EXIT
    trap 'exit 1' HUP INT TERM
    /bin/cp -P "$source" "$stage/helper"
    test -f "$stage/helper" && test ! -L "$stage/helper"
    actual=$(/usr/bin/shasum -a 256 "$stage/helper")
    test "${actual%% *}" = "$expected"
    /usr/bin/codesign --verify --strict "$stage/helper"
    /usr/bin/printf %s "$plistContents" > "$stage/daemon.plist"
    /usr/bin/plutil -lint "$stage/daemon.plist" >/dev/null
    """

    static let installShellScript = payloadStagingScript + "\n" + """
    /usr/sbin/chown root:wheel "$stage/helper" "$stage/daemon.plist"
    /bin/chmod 755 "$stage/helper"
    /bin/chmod 644 "$stage/daemon.plist"
    /bin/launchctl bootout system/com.batteryarchive.helper 2>/dev/null || true
    /bin/mv -fh "$stage/helper" "$destination"
    /bin/mv -fh "$stage/daemon.plist" "$plistDestination"
    /bin/launchctl bootstrap system/ "$plistDestination"
    """

    static var installAppleScript: String {
        // Pass the shell program and paths as quoted argv, never interpolate user paths.
        """
        on run argv
            set shellProgram to item 7 of argv
            set shellCommand to "/bin/mkdir -p /Library/PrivilegedHelperTools && /bin/sh -c " & quoted form of shellProgram & " --"
            repeat with i from 1 to 4
                set shellCommand to shellCommand & " " & quoted form of (item i of argv)
            end repeat
            set shellCommand to shellCommand & " " & quoted form of (item 6 of argv)
            do shell script shellCommand with administrator privileges with prompt (item 5 of argv)
        end run
        """
    }

    private func staticCodeCDHash(at url: URL) -> String? {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess,
              let code else { return nil }
        var infoCF: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &infoCF) == errSecSuccess,
              let info = infoCF as? [String: Any],
              let hash = info[kSecCodeInfoUnique as String] as? Data,
              !hash.isEmpty else { return nil }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func currentExecutableCDHash() -> String? {
        guard let executableURL = Bundle.main.executableURL else { return nil }
        return staticCodeCDHash(at: executableURL)
    }

    /// Expected payload digest; the privileged installer verifies its private staged copy.
    static func sha256Hex(at path: String) -> String? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// 执行安装
    private func installHelper(from helperPath: String) -> Bool {
        let helperID = "com.batteryarchive.helper"
        let installPath = "/Library/PrivilegedHelperTools/\(helperID)"
        let plistPath = "/Library/LaunchDaemons/\(helperID).plist"
        guard let authorizedClientCDHash = currentExecutableCDHash() else {
            helperInstallerLogger.error("Cannot bind Helper to the current signed executable")
            return false
        }
        guard let expectedSourceSHA256 = Self.sha256Hex(at: helperPath) else {
            helperInstallerLogger.error("Cannot hash bundled Helper before install")
            return false
        }

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>\(helperID)</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(installPath)</string>
            </array>
            <key>MachServices</key>
            <dict>
                <key>\(helperID)</key>
                <true/>
            </dict>
            <key>EnvironmentVariables</key>
            <dict>
                <key>BATTERYARCHIVE_AUTHORIZED_CLIENT_CDHASH</key>
                <string>\(authorizedClientCDHash)</string>
            </dict>
        </dict>
        </plist>
        """

        let script = Self.installAppleScript

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e", script, "--",
            helperPath,
            installPath,
            plistPath,
            plistContent,
            "\(AppBrand.displayName)需要安装后台服务以读取 CPU/GPU 分项功耗",
            expectedSourceSHA256,
            Self.installShellScript,
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                return true
            }
        } catch {
            helperInstallerLogger.error("Failed to install helper: \(error.localizedDescription)")
        }
        return false
    }

    /// 卸载 helper：bootout 停止 root 守护进程并删除二进制与 plist（弹一次管理员密码框）。
    /// 返回 false 表示用户取消密码框或卸载失败（守护进程保留，但 app 侧不再调用；
    /// helper 4.0 起 powermetrics 有 60s 空闲自停，保留也不产生持续开销）。
    @discardableResult
    func uninstallHelper() -> Bool {
        let installPath = "/Library/PrivilegedHelperTools/\(Self.helperIdentifier)"
        let plistPath = "/Library/LaunchDaemons/\(Self.helperIdentifier).plist"

        // 已不在则无需提权
        guard FileManager.default.fileExists(atPath: installPath)
            || FileManager.default.fileExists(atPath: plistPath) else {
            return true
        }

        let script = """
        on run argv
            set shellCommand to "(/bin/launchctl bootout " & quoted form of (item 1 of argv) & " 2>/dev/null || true) && /bin/rm -f " & quoted form of (item 2 of argv) & " " & quoted form of (item 3 of argv)
            do shell script shellCommand with administrator privileges with prompt (item 4 of argv)
        end run
        """
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        task.arguments = [
            "-e", script, "--",
            "system/\(Self.helperIdentifier)",
            installPath,
            plistPath,
            "\(AppBrand.displayName)需要移除后台服务",
        ]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice

        do {
            try task.run()
            task.waitUntilExit()
            if task.terminationStatus == 0 {
                helperInstallerLogger.info("Helper uninstalled")
                return true
            }
            helperInstallerLogger.error("Helper uninstall cancelled or failed")
            return false
        } catch {
            helperInstallerLogger.error("Failed to uninstall helper: \(error.localizedDescription)")
            return false
        }
    }

}
