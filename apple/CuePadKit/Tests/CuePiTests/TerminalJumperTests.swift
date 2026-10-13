#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import CuePi

/// "跳到会话所在终端"的策略选择：用假系统记录会执行哪些 tmux 命令 / AppleScript / 激活。
struct TerminalJumperTests {
    /// 配置项由测试在用之前设好；执行记录由被测代码在别的任务里写，放在锁里。
    final class FakeSystem: PiTerminalSystem, @unchecked Sendable {
        private struct Calls {
            var runs: [[String]] = []
            var scripts: [String] = []
            var activated: [String] = []
        }
        private let calls = Mutex(Calls())
        var tmuxClients = "100 /dev/ttys004\n300 /dev/ttys021\n200 /dev/ttys007\n" // "<最近活动> <tty>"
        var tmuxSwitchStatus: Int32 = 0
        var scriptResult: Result<String, any Error> = .success("ok")
        var canActivate = true

        var runs: [[String]] { calls.withLock { $0.runs } }
        var scripts: [String] { calls.withLock { $0.scripts } }
        var activated: [String] { calls.withLock { $0.activated } }

        func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
            calls.withLock { $0.runs.append([executable] + arguments) }
            if arguments.contains("list-clients") { return (0, tmuxClients) }
            if arguments.contains("switch-client") { return (tmuxSwitchStatus, "") }
            return (0, "")
        }
        func appleScript(_ source: String) async throws -> String {
            calls.withLock { $0.scripts.append(source) }
            return try scriptResult.get()
        }
        func activate(bundleID: String) async -> Bool {
            calls.withLock { $0.activated.append(bundleID) }
            return canActivate
        }
    }

    struct Denied: Error {}

    private func session(_ terminal: PiTerminal, cwd: String = "/Users/me/proj") -> PiSession {
        PiSession(id: "s.1", sessionID: "s", agent: .pi, sessionFile: nil, pid: 1, cwd: URL(filePath: cwd), 
                  terminal: terminal, extensionVersion: 1, state: .settled, stateSince: Date())
    }

    private let appleTerminal = "com.apple.Terminal"
    private let ghostty = "com.mitchellh.ghostty"

    /// 找不到标签页，或没有"自动化"权限（脚本抛错）：都退到只激活应用，并说明原因。
    @Test(arguments: [Result<String, any Error>.success("notfound"), .failure(Denied())])
    func tabNotFoundOrAutomationDeniedFallsBackToActivatingTheApp(script: Result<String, any Error>) async {
        let sys = FakeSystem()
        sys.scriptResult = script
        let r = await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(tty: "ttys015", bundleID: appleTerminal)))
        #expect(r.precision == .application)
        #expect(sys.activated == [appleTerminal])
        #expect(r.note?.isEmpty == false)
    }

}
#endif
