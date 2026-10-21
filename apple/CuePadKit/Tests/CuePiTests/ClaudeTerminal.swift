#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePi

struct TmuxFailed: Error { let command: String }
struct NoQuestion: Error, CustomStringConvertible { let description: String }
struct Stuck: Error, CustomStringConvertible { let description: String }

/// 私有 tmux 服务器里的一个 Claude Code（`exec claude`：pane 的进程就是 Claude Code）。
@MainActor
final class ClaudeTerminal {
    let pid: Int32
    private let server: Int32
    private let name: String

    init(testbed: ClaudeTestbed, arguments: [String]) async throws {
        name = "cpt-\(UUID().uuidString.prefix(8))"
        let environment = ProcessInfo.processInfo.environment.filter { key, _ in !["TMUX", "CLAUDE", "CUEPAD", "HERDR"].contains { key.hasPrefix($0) } }
            .merging(testbed.environment) { $1 }
        _ = try await Self.tmux(name, ["-f", "/dev/null", "new-session", "-d", "-x", "200", "-y", "50", "-c", testbed.work.path,
                                       (["exec", claudeURL!.path] + arguments).joined(separator: " ")], environment: environment)
        let ids = try await Self.tmux(name, ["display-message", "-p", "#{pane_pid} #{pid}"], environment: environment)
            .split(separator: " ").compactMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard ids.count == 2 else { throw TmuxFailed(command: "display-message") }
        pid = ids[0]
        server = ids[1]
    }

    @discardableResult
    private static func tmux(_ name: String, _ arguments: [String], environment: [String: String]) async throws -> String {
        guard let result = await ChildProcess.run(tmuxURL!, ["-L", name] + arguments, environment: environment, timeout: .seconds(10)),
              result.status == 0 else {
            throw TmuxFailed(command: arguments.joined(separator: " "))
        }
        return result.output
    }

    /// 在终端里打一句话，等它出现在输入框里再回车（一口气送进去的字被当作粘贴，紧跟着的回车会被吞掉）
    func type(_ text: String) async throws {
        try await Self.tmux(name, ["send-keys", "-l", text], environment: [:])
        try await eventually("输入框里有这句话") { await screen.contains(String(text.prefix(20))) }
        try await keys("Enter")
    }

    func keys(_ keys: String...) async throws { try await Self.tmux(name, ["send-keys"] + keys, environment: [:]) }

    var screen: String {
        get async { (try? await Self.tmux(name, ["capture-pane", "-p"], environment: [:])) ?? "" }
    }

    /// 像在终端里按 Ctrl-C 那样让它退出（它自己收拾收件箱 socket），再停掉这个 tmux 服务器。
    func stop() {
        kill(pid, SIGINT)
        kill(server, SIGTERM)
    }
}
#endif
