#if os(macOS)
import AppKit
import Foundation

public struct JumpResult: Sendable, Equatable {
    public enum Precision: Sendable, Equatable {
        case tab
        case application
        case failed
    }

    public var precision: Precision
    public var note: String?
}

/// Ghostty 不暴露 tty，也没有传给子进程的终端 ID，所以按工作目录找终端，唯一匹配才聚焦。iTerm2/kitty/WezTerm 各有自己的脚本接口，尚未接入，只能激活应用。
/// `tmux` 按 `ExecutableLocator.standard` 的 PATH 找（GUI 应用的 PATH 很短）、AppleScript 在主线程执行、应用激活走 `NSRunningApplication`。
/// 首次控制某个应用时系统会弹“自动化”授权，App 需要在 Info.plist 里写 `NSAppleEventsUsageDescription`。
public struct TerminalJumper: Sendable {
    private static let appleTerminal = "com.apple.Terminal"
    private static let ghostty = "com.mitchellh.ghostty"

    public init() {}

    public func jump(to session: Session) async -> JumpResult {
        let terminal = session.terminal
        var tty = terminal.tty
        var notes: [String] = []

        if let pane = terminal.tmuxPane, let socket = terminal.tmuxSocketPath {
            if await run("tmux", ["-S", socket, "switch-client", "-t", pane]).status == 0 {
                tty = await hostingClientTTY(socket: socket, pane: pane) ?? tty
            } else {
                notes.append(String(localized: "tmux 没能切到 \(pane)（会话可能没有附着的客户端）"))
            }
        }

        guard let bundleID = terminal.bundleID else {
            return JumpResult(precision: .failed, note: String(localized: "不知道会话运行在哪个终端应用里"))
        }

        let script: String? = switch bundleID {
        case Self.appleTerminal: tty.map(Self.appleTerminalScript(tty:))
        case Self.ghostty: Self.ghosttyScript(cwd: session.cwd.path)
        default: nil
        }
        if let script {
            do {
                let result = try await appleScript(script)
                if result == "ok" { return JumpResult(precision: .tab, note: notes.first) }
                notes.append(Self.explain(scriptResult: result))
            } catch {
                notes.append(String(localized: "无法控制该终端应用（可能没有授予自动化权限）：\(error.localizedDescription)"))
            }
        } else if bundleID == Self.appleTerminal {
            notes.append(String(localized: "没有 tty 信息，无法定位标签页"))
        }

        guard await activate(bundleID: bundleID) else {
            return JumpResult(precision: .failed, note: String(localized: "终端应用 \(bundleID) 没有在运行"))
        }
        return JumpResult(precision: .application, note: notes.first)
    }

    /// 最近活动的 tmux 客户端 = tmux 切换时选中的那个
    private func hostingClientTTY(socket: String, pane: String) async -> String? {
        let listed = await run("tmux", ["-S", socket, "list-clients", "-t", pane, "-F", "#{client_activity} #{client_tty}"])
        guard listed.status == 0 else { return nil }
        return listed.output.split(separator: "\n")
            .compactMap { line -> (Int, String)? in
                let fields = line.split(separator: " ", maxSplits: 1)
                guard fields.count == 2, let activity = Int(fields[0]) else { return nil }
                return (activity, String(fields[1]))
            }
            .max { $0.0 < $1.0 }?.1
    }

    private static func explain(scriptResult: String) -> String {
        if scriptResult.hasPrefix("ambiguous:"), let count = Int(scriptResult.dropFirst("ambiguous:".count)) {
            return String(localized: "有 \(count) 个终端匹配，无法确定是哪一个")
        }
        return String(localized: "没有工作目录或 tty 匹配的终端/标签页")
    }

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    private static func appleTerminalScript(tty: String) -> String {
        let device = tty.hasPrefix("/dev/") ? tty : "/dev/" + tty
        return """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is \(quoted(device)) then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "ok"
                    end if
                end repeat
            end repeat
        end tell
        return "notfound"
        """
    }

    private static func ghosttyScript(cwd: String) -> String {
        """
        tell application "Ghostty"
            set matches to every terminal whose working directory is \(quoted(cwd))
            if (count of matches) is 1 then
                focus (item 1 of matches)
                return "ok"
            end if
            if (count of matches) is 0 then return "notfound"
            return "ambiguous:" & (count of matches)
        end tell
        """
    }

    private func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        let env = URL(filePath: "/usr/bin/env")
        return await ChildProcess.run(env, [executable] + arguments, environment: ExecutableLocator.standard.environment(launching: env)) ?? (-1, "")
    }

    /// 未授权自动化等失败时抛错。
    private func appleScript(_ source: String) async throws -> String {
        try await MainActor.run {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { throw ScriptError(message: "invalid script") }
            let result = script.executeAndReturnError(&error)
            if let error { throw ScriptError(message: error[NSAppleScript.errorMessage] as? String ?? "\(error)") }
            return result.stringValue ?? ""
        }
    }

    private func activate(bundleID: String) async -> Bool {
        await MainActor.run {
            NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first?.activate() ?? false
        }
    }

    private struct ScriptError: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }
}
#endif
