#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// "跳到会话所在终端"的策略选择：用假系统记录会执行哪些 tmux 命令 / AppleScript / 激活。
struct TerminalJumperTests {
    final class FakeSystem: PiTerminalSystem, @unchecked Sendable {
        private let lock = NSLock()
        private var _runs: [[String]] = []
        private var _scripts: [String] = []
        private var _activated: [String] = []
        var tmuxClients = "100 /dev/ttys004\n300 /dev/ttys021\n200 /dev/ttys007\n" // "<最近活动> <tty>"
        var tmuxSwitchStatus: Int32 = 0
        var scriptResult: Result<String, any Error> = .success("ok")
        var canActivate = true

        var runs: [[String]] { lock.withLock { _runs } }
        var scripts: [String] { lock.withLock { _scripts } }
        var activated: [String] { lock.withLock { _activated } }

        func run(_ executable: String, _ arguments: [String]) async -> (status: Int32, output: String) {
            lock.withLock { _runs.append([executable] + arguments) }
            if arguments.contains("list-clients") { return (0, tmuxClients) }
            if arguments.contains("switch-client") { return (tmuxSwitchStatus, "") }
            return (0, "")
        }
        func appleScript(_ source: String) async throws -> String {
            lock.withLock { _scripts.append(source) }
            return try scriptResult.get()
        }
        func activate(bundleID: String) async -> Bool {
            lock.withLock { _activated.append(bundleID) }
            return canActivate
        }
    }

    struct Denied: Error {}

    private func session(_ terminal: PiTerminal, cwd: String = "/Users/me/proj") -> PiSession {
        PiSession(id: "s.1", sessionID: "s", sessionFile: nil, pid: 1, cwd: URL(filePath: cwd), mode: "tui", model: nil,
                  terminal: terminal, extensionVersion: 1, state: .idle, stateSince: Date())
    }

    private let appleTerminal = "com.apple.Terminal"
    private let ghostty = "com.mitchellh.ghostty"

    @Test func appleTerminalSelectsTheTabByTTY() async {
        let sys = FakeSystem()
        let r = await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(tty: "ttys015", bundleID: appleTerminal)))
        #expect(r.precision == .tab)
        #expect(sys.scripts.count == 1 && sys.scripts[0].contains("/dev/ttys015") && sys.scripts[0].contains("Terminal"))
        #expect(sys.runs.isEmpty)
    }

    @Test func tmuxPaneIsSelectedAndHostingClientTTYDrivesTheTabLookup() async {
        let sys = FakeSystem()
        let terminal = PiTerminal(tty: "ttys015", bundleID: appleTerminal, tmuxPane: "%3", tmuxSocketPath: "/private/tmp/tmux-501/default")
        let r = await PiTerminalJumper(system: sys).jump(to: session(terminal))
        let switchCmd = sys.runs.first { $0.contains("switch-client") }
        #expect(switchCmd?.contains("%3") == true)
        #expect(switchCmd?.contains("/private/tmp/tmux-501/default") == true)
        #expect(r.tmuxPaneSelected)
        #expect(r.precision == .tab)
        // pane 自己的 tty 在 tmux 里是伪终端，应该用承载它的 tmux 客户端（最近活动的那个）的 tty 去找标签页
        #expect(sys.scripts.first?.contains("/dev/ttys021") == true)
        #expect(sys.scripts.first?.contains("ttys015") == false)
    }

    @Test func tabNotFoundFallsBackToActivatingTheApp() async {
        let sys = FakeSystem()
        sys.scriptResult = .success("notfound")
        let r = await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(tty: "ttys015", bundleID: appleTerminal)))
        #expect(r.precision == .application)
        #expect(sys.activated == [appleTerminal])
        #expect(r.note != nil)
    }

    @Test func automationDeniedFallsBackToActivatingTheAppAndSaysWhy() async {
        let sys = FakeSystem()
        sys.scriptResult = .failure(Denied())
        let r = await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(tty: "ttys015", bundleID: appleTerminal)))
        #expect(r.precision == .application)
        #expect(sys.activated == [appleTerminal])
        #expect(r.note?.isEmpty == false)
    }

    @Test func ghosttyFocusesTheSingleTerminalWithMatchingWorkingDirectory() async {
        let sys = FakeSystem()
        let r = await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(bundleID: ghostty), cwd: "/Users/me/proj"))
        #expect(r.precision == .tab)
        #expect(sys.scripts.first?.contains("Ghostty") == true && sys.scripts.first?.contains("/Users/me/proj") == true)
    }

    @Test func ghosttyWithSeveralMatchesOnlyActivatesTheApp() async {
        let sys = FakeSystem()
        sys.scriptResult = .success("ambiguous:2")
        let r = await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(bundleID: ghostty)))
        #expect(r.precision == .application)
        #expect(sys.activated == [ghostty])
        #expect(r.note?.isEmpty == false)
    }

    @Test func unknownTerminalAppIsJustActivated() async {
        let sys = FakeSystem()
        let r = await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(bundleID: "com.example.term")))
        #expect(r.precision == .application)
        #expect(sys.activated == ["com.example.term"] && sys.scripts.isEmpty)
    }

    @Test func failsWhenNothingIsKnownOrAppIsNotRunning() async {
        let sys = FakeSystem()
        #expect(await PiTerminalJumper(system: sys).jump(to: session(PiTerminal())).precision == .failed)
        #expect(await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(bundleID: "com.example.term"))).precision == .application)
        sys.canActivate = false
        #expect(await PiTerminalJumper(system: sys).jump(to: session(PiTerminal(bundleID: "com.example.term"))).precision == .failed)
    }

    @Test func failedTmuxSwitchIsReportedButTheAppIsStillActivated() async {
        let sys = FakeSystem()
        sys.tmuxSwitchStatus = 1
        let terminal = PiTerminal(bundleID: "com.example.term", tmuxPane: "%3", tmuxSocketPath: "/tmp/tmux-501/default")
        let r = await PiTerminalJumper(system: sys).jump(to: session(terminal))
        #expect(!r.tmuxPaneSelected)
        #expect(r.precision == .application)
        #expect(sys.activated == ["com.example.term"])
    }
}
#endif
