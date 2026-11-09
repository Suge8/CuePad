#if os(macOS)
import CueStore
import Darwin
import Foundation

/// 收件箱送来的话没带令牌（`ClaudeTerminalSession.inboxToken`）时，跳过权限确认的会话把它扣在终端里等你批准
/// （"Held message from another session"），不交给模型；别的模式照收（2.1.318 实测）。
/// 令牌只在钩子的环境里，别处拿不到（2.1.318 实测）：它起好收件箱后才放进自己的环境，`KERN_PROCARGS2` 里是启动时的那份；
/// 会话登记目录里发布的 `<pid>.<hash>.key` 是给同伴会话的另一种令牌，带上它照样扣下；话里自报的权限模式（`from_mode`）它不认。
/// 它此刻在哪个模式，外面也看不到（Shift-Tab 随时换，会话文件与登记文件都不记）。所以只看它进不进得了这个模式：
/// 启动时就在跳过权限确认，或带了 `--allow-dangerously-skip-permissions`（它的 `isBypassPermissionsModeAvailable`）。
/// 启动时的模式按它的先后取（2.1.318 的 `vpo`）：命令行、agent 定义的 `permissionMode`、设置的 `permissions.defaultMode`、
/// `--inherit-permission-mode`。agent 定义给的跳过权限确认它不认（实测起来是 auto，Shift-Tab 也轮不到），不带这些接着的会话也回不去（实测）。
enum ClaudeBypass {
    /// 读不到它的命令行（进程没了）也算进得了：宁可不发。
    /// 设置不分先后，哪份说了都算：它自己的配置目录（环境里的 `CLAUDE_CONFIG_DIR`，没有时是 `home`）里的用户设置与服务端下发的
    /// `remote-settings.json`、托管设置（`managed-settings.json`、`managed-settings.d/`、MDM 的描述文件）、`--settings`，
    /// 以及工作目录及其上级的 `.claude` 里的（它不让这两份给跳过权限确认，多看不会漏）。
    static func reachable(pid: Int32, cwd: URL, home: URL) -> Bool {
        guard let process = launch(of: pid) else { return true }
        let arguments = process.arguments
        if arguments.contains(where: ["--dangerously-skip-permissions", "--allow-dangerously-skip-permissions"].contains) { return true }
        if let mode = value(of: "--permission-mode", in: arguments) { return mode == bypass }
        if value(of: "--inherit-permission-mode", in: arguments) == bypass { return true }
        let config = process.environment["CLAUDE_CONFIG_DIR"].map { URL(filePath: $0, directoryHint: .isDirectory) } ?? home
        let managed = URL(filePath: "/Library/Application Support/ClaudeCode", directoryHint: .isDirectory)
        var files = [config.appending(path: "settings.json"), config.appending(path: "remote-settings.json"), managed.appending(path: "managed-settings.json")]
        files += ((try? FileManager.default.contentsOfDirectory(at: managed.appending(path: "managed-settings.d"), includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension == "json" }
        var directory = cwd.standardizedFileURL
        while true {
            files += ["settings.json", "settings.local.json"].map { directory.appending(path: ".claude/\($0)") }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        var settings = files.compactMap { try? Data(contentsOf: $0) }
        settings += ["/Library/Managed Preferences/\(NSUserName())", "/Library/Managed Preferences"].compactMap { folder in
            (try? Data(contentsOf: URL(filePath: "\(folder)/com.anthropic.claudecode.plist")))
                .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) }
                .flatMap { try? JSONSerialization.data(withJSONObject: $0) }
        }
        if let flag = value(of: "--settings", in: arguments) {
            settings.append(flag.hasPrefix("{") ? Data(flag.utf8) : (try? Data(contentsOf: URL(filePath: flag, relativeTo: cwd))) ?? Data())
        }
        return settings.compactMap(JSONValue.parse).contains(where: grantsBypass)
    }

    /// 服务端下发的那份外面包着什么没核实：哪一层写了都算。
    private static func grantsBypass(_ value: JSONValue) -> Bool {
        if value["permissions"]?["defaultMode"]?.string == bypass { return true }
        return (value.object.map { Array($0.values) } ?? value.array ?? []).contains(where: grantsBypass)
    }

    private static let bypass = "bypassPermissions"

    private static func value(of option: String, in arguments: [String]) -> String? {
        for (index, argument) in arguments.enumerated() {
            if argument == option, index + 1 < arguments.count { return arguments[index + 1] }
            if argument.hasPrefix(option + "=") { return String(argument.dropFirst(option.count + 1)) }
        }
        return nil
    }

    /// 进程启动时的参数（不含程序名）与环境（`KERN_PROCARGS2`：参数个数、可执行文件路径、各个参数、各个环境变量，以 \0 分隔）。
    private static func launch(of pid: Int32) -> (arguments: [String], environment: [String: String])? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let count = buffer.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        let strings = buffer[MemoryLayout<Int32>.size..<size].split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
        guard count >= 1, strings.count > count else { return nil }
        let environment = strings.dropFirst(count + 1).reduce(into: [String: String]()) { environment, entry in
            guard let equals = entry.firstIndex(of: "=") else { return }
            environment[String(entry[..<equals])] = String(entry[entry.index(after: equals)...])
        }
        return (Array(strings[2..<(count + 1)]), environment)
    }
}
#endif
