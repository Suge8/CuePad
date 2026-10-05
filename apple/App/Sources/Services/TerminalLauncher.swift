#if os(macOS)
import AppKit
import Foundation

/// 在终端里要运行的东西：在 `directory` 里、带 `environment` 运行 `executable arguments…`。
struct TerminalCommand: Equatable, Sendable {
    var directory: URL
    var executable: URL
    var arguments: [String]
    var environment: [String: String]

    /// 交给终端的 shell 的一行：`cd <目录> && exec env K=V <程序> <参数…>`，每一段都按 shell 单引号转义。
    var shellLine: String {
        let env = environment.sorted { $0.key < $1.key }.map { "\($0.key)=\(Self.quoted($0.value))" }
        let program = ([executable.path] + arguments).map(Self.quoted)
        return "cd \(Self.quoted(directory.path)) && exec " + (env.isEmpty ? [] : ["env"] + env).joined(separator: " ")
            + (env.isEmpty ? "" : " ") + program.joined(separator: " ")
    }

    static func quoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: #"'\''"#) + "'" }
}

/// 在指定终端里新开一个窗口运行命令（真实实现见 `LiveTerminalLauncher`，测试换成只记录参数的替身）。
@MainActor
protocol TerminalLaunching {
    func open(_ command: TerminalCommand, in app: PiTerminalApp) async throws
}

/// 各终端用它们官方支持的方式开新窗口并运行命令：终端与 iTerm 用 AppleScript（首次会请求自动化权限），
/// Ghostty 用 `open -na` 带 `-e` 参数，Warp 用启动配置（launch configuration）文件加 `warp://launch/` 链接。
@MainActor
struct LiveTerminalLauncher: TerminalLaunching {
    func open(_ command: TerminalCommand, in app: PiTerminalApp) async throws {
        switch app {
        case .terminal:
            try runAppleScript("""
                tell application "Terminal"
                    activate
                    do script "\(Self.appleScriptEscaped(command.shellLine))"
                end tell
                """)
        case .iterm:
            try runAppleScript("""
                tell application "iTerm"
                    activate
                    set newWindow to (create window with default profile)
                    tell current session of newWindow to write text "\(Self.appleScriptEscaped(command.shellLine))"
                end tell
                """)
        case .ghostty:
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            try run("/usr/bin/open", ["-na", "Ghostty", "--args", "-e", shell, "-lc", command.shellLine])
        case .warp:
            try openInWarp(command)
        }
    }

    private func runAppleScript(_ source: String) throws {
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
        if let error { throw SendError.terminalFailed(error[NSAppleScript.errorMessage] as? String ?? "\(error)") }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        if process.terminationStatus != 0 { throw SendError.terminalFailed("\(tool) 退出码 \(process.terminationStatus)") }
    }

    /// Warp 的链接只能开目录、不能带命令，要运行命令得用启动配置：写一份（每次覆盖同一份）再按路径打开。
    private func openInWarp(_ command: TerminalCommand) throws {
        let directory = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".warp/launch_configurations")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: "cuepad.yaml")
        let yaml = """
            ---
            name: CuePad
            windows:
              - tabs:
                  - layout:
                      cwd: \(Self.yamlQuoted(command.directory.path))
                      commands:
                        - exec: \(Self.yamlQuoted(command.shellLine))
            """
        try yaml.write(to: file, atomically: true, encoding: .utf8)
        var components = URLComponents()
        components.scheme = "warp"
        components.host = "launch"
        components.path = file.path
        guard let url = components.url, NSWorkspace.shared.open(url) else { throw SendError.terminalFailed("Warp 没能打开启动配置") }
    }

    private static func appleScriptEscaped(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func yamlQuoted(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
#endif
