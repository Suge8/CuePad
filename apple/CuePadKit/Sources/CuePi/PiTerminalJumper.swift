#if os(macOS)
import AppKit
import Foundation

public struct PiJumpResult: Sendable, Equatable {
    public enum Precision: Sendable, Equatable {
        /// 精确到标签页（或分屏）并已聚焦
        case tab
        /// 只激活了终端应用，没能定位到具体标签页
        case application
        case failed
    }

    public var precision: Precision
    /// 会话在 tmux 里时，是否已把 tmux 切到该 pane
    public var tmuxPaneSelected: Bool
    /// 精度降级/失败的原因，给界面提示用
    public var note: String?
}

/// 跳转要用到的系统能力。生产实现是 `LivePiTerminalSystem`；测试用假实现记录调用。
public protocol PiTerminalSystem: Sendable {
    /// 运行外部命令（如 `tmux`），返回退出码与标准输出
    func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String)
    /// 执行 AppleScript，返回结果文字；未授权自动化等失败时抛错
    func appleScript(_ source: String) async throws -> String
    /// 激活应用；应用没在运行返回 false
    func activate(bundleID: String) async -> Bool
}

/// "跳到该会话所在终端"。用 hello 里的终端信息，按能做到的最高精度定位：
/// - tmux：先把 tmux 切到该 pane，并用承载它的 tmux 客户端的 tty 去找标签页；
/// - Terminal.app：按 tty 选中标签页并前置窗口；
/// - Ghostty：按工作目录找终端，唯一匹配才聚焦（Ghostty 不暴露 tty，也没有传给子进程的终端 ID）；
/// - 其他终端：只能激活应用。iTerm2/kitty/WezTerm 各有自己的脚本接口，尚未接入。
public struct PiTerminalJumper: Sendable {
    private let system: any PiTerminalSystem

    private static let appleTerminal = "com.apple.Terminal"
    private static let ghostty = "com.mitchellh.ghostty"

    public init(system: any PiTerminalSystem = LivePiTerminalSystem()) {
        self.system = system
    }

    public func jump(to session: PiSession) async -> PiJumpResult {
        let terminal = session.terminal
        var tty = terminal.tty
        var tmuxSelected = false
        var notes: [String] = []

        if let pane = terminal.tmuxPane, let socket = terminal.tmuxSocketPath {
            tmuxSelected = await system.run("tmux", ["-S", socket, "switch-client", "-t", pane]).status == 0
            if tmuxSelected {
                tty = await hostingClientTTY(socket: socket, pane: pane) ?? tty
            } else {
                notes.append("tmux 没能切到 \(pane)（会话可能没有附着的客户端）")
            }
        }

        guard let bundleID = terminal.bundleID else {
            return PiJumpResult(precision: .failed, tmuxPaneSelected: tmuxSelected, note: "不知道会话运行在哪个终端应用里")
        }

        let script: String? = switch bundleID {
        case Self.appleTerminal: tty.map(Self.appleTerminalScript(tty:))
        case Self.ghostty: Self.ghosttyScript(cwd: session.cwd.path)
        default: nil
        }
        if let script {
            do {
                let result = try await system.appleScript(script)
                if result == "ok" { return PiJumpResult(precision: .tab, tmuxPaneSelected: tmuxSelected, note: notes.first) }
                notes.append(Self.explain(scriptResult: result))
            } catch {
                notes.append("无法控制该终端应用（可能没有授予自动化权限）：\(error.localizedDescription)")
            }
        } else if bundleID == Self.appleTerminal {
            notes.append("没有 tty 信息，无法定位标签页")
        }

        guard await system.activate(bundleID: bundleID) else {
            return PiJumpResult(precision: .failed, tmuxPaneSelected: tmuxSelected, note: "终端应用 \(bundleID) 没有在运行")
        }
        return PiJumpResult(precision: .application, tmuxPaneSelected: tmuxSelected, note: notes.first)
    }

    /// 最近活动的 tmux 客户端 = tmux 切换时选中的那个
    private func hostingClientTTY(socket: String, pane: String) async -> String? {
        let listed = await system.run("tmux", ["-S", socket, "list-clients", "-t", pane, "-F", "#{client_activity} #{client_tty}"])
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
        if scriptResult.hasPrefix("ambiguous:") { return "有 \(scriptResult.dropFirst("ambiguous:".count)) 个终端匹配，无法确定是哪一个" }
        return "没有工作目录或 tty 匹配的终端/标签页"
    }

    // MARK: AppleScript

    private static func quoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func appleTerminalScript(tty: String) -> String {
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

    static func ghosttyScript(cwd: String) -> String {
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
}

/// 生产实现：`tmux` 按 `ExecutableLocator.standard` 的 PATH 找（GUI 应用的 PATH 很短）、AppleScript 在主线程执行、
/// 应用激活走 `NSRunningApplication`。首次控制某个应用时系统会弹"自动化"授权，App 需要在
/// Info.plist 里写 `NSAppleEventsUsageDescription`。
public struct LivePiTerminalSystem: PiTerminalSystem {
    public init() {}

    public func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
        let env = URL(filePath: "/usr/bin/env")
        return await runCapturing(env, [executable] + arguments, environment: ExecutableLocator.standard.environment(launching: env)) ?? (-1, "")
    }

    public func appleScript(_ source: String) async throws -> String {
        try await MainActor.run {
            var error: NSDictionary?
            guard let script = NSAppleScript(source: source) else { throw ScriptError(message: "invalid script") }
            let result = script.executeAndReturnError(&error)
            if let error { throw ScriptError(message: error[NSAppleScript.errorMessage] as? String ?? "\(error)") }
            return result.stringValue ?? ""
        }
    }

    public func activate(bundleID: String) async -> Bool {
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
