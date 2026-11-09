#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 终端里的 Claude Code 起好之前（登记文件里没有 `status`）CuePad 不往它的收件箱送话：一直起不好就报没发出，
/// 等着时进程退了就马上报会话已结束（确定没发出），起好了再发就送到。
@MainActor
@Suite(RealAgents.taped(.claudeCode))
struct ClaudeTerminalReadyTests {
    @Test func aMessageToATerminalSessionThatNeverGetsReadyIsNotSent() async throws {
        let directory = URL(filePath: "/tmp/cpr-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = directory.appending(path: "registry.json")
        try Data(#"{"pid": 1}"#.utf8).write(to: registry)
        let inbox = try Inbox(at: directory.appending(path: "inbox.sock").path)

        let clock = ManualTiming()
        let terminal = ClaudeTerminalSession(
            id: "t", pid: getpid(), bridge: PiBridge(socketDirectory: directory), gate: PresenceGate(presence: TestPresence()),
            inbox: inbox.path, registry: registry, timing: clock.timing, runningSince: nil, waiting: false)
        let sending = Task { try await terminal.send(PiMessage(text: "你好"), in: "t") }
        try await eventually("在等它起好，或已经送了") { clock.sleeperCount > 0 || inbox.knocked }
        clock.advance(AgentTimeouts.terminalReady)
        await #expect(throws: PiBridgeError.rejected("not_ready")) { try await sending.value }
        #expect(!inbox.knocked, "没起好时收件箱里不该有话")

        try Data(#"{"pid": 1, "status": "idle"}"#.utf8).write(to: registry, options: .atomic)
        try await terminal.send(PiMessage(text: "你好"), in: "t")
        #expect(inbox.knocked)
    }

    /// 测试台的钟不走（`noDeadline`）：等待只可能因进程退出而结束。报的是确定没发出的那种（`DeliveryRefusal.definitelyNotHanded` 认 `unknownSession`）。
    @Test func aTerminalSessionThatExitsBeforeItIsReadyEndsTheDeliveryAtOnce() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let fake = try FakeTerminal(testbed, config: testbed.config, status: nil)
            let session = try await fake.appear()
            let outcome = Outcome()
            Task {
                do { try await testbed.bridge.send(PiMessage(text: "你好"), to: session.id) } catch { outcome.error = error }
                outcome.done = true
            }
            try await Task.sleep(for: .milliseconds(300))  // 让它进到等起好
            #expect(!outcome.done && testbed.bridge.session(id: session.id) != nil, "进程退出前该一直在等")

            fake.kill()
            try await eventually("进程一退投送就结束") { outcome.done }
            #expect(outcome.error as? PiBridgeError == .unknownSession(session.id))
            #expect(!fake.inbox.knocked, "话没写进收件箱")
        }
    }

    /// 用户给终端里的 Claude Code 另设了配置目录：登记文件在那里，CuePad 读的配置目录里没有。
    @Test func aTerminalSessionWithItsOwnConfigDirectoryGetsTheMessage() async throws {
        try await ClaudeTestbed.run { testbed in
            try testbed.startConnected()
            let fake = try FakeTerminal(testbed, config: testbed.root.appending(path: "own-config"), status: "idle")
            let session = try await fake.appear()
            let outcome = Outcome()
            Task {
                do { try await testbed.bridge.send(PiMessage(text: "你好"), to: session.id) } catch { outcome.error = error }
                outcome.done = true
            }
            try await eventually("送出去了") { outcome.done }
            #expect(outcome.error == nil && fake.inbox.knocked, "\(String(describing: outcome.error))")
        }
    }
}

@MainActor
private final class Outcome {
    var done = false
    var error: (any Error)?
}

/// 收件箱的替身：只看有没有人连上来（`ClaudeInbox.post` 连上、写完就关）。
private final class Inbox {
    let path: String
    private let listener: Int32

    init(at path: String) throws {
        self.path = path
        listener = try UnixSocket.listen(path)
    }

    deinit { close(listener) }

    var knocked: Bool {
        var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
        return poll(&waiting, 1, 0) == 1
    }
}

/// 终端里的 Claude Code 的替身：一个真进程（`sleep`）当它，按 Claude Code 的样子写登记文件、发 `SessionStart` 钩子。
@MainActor
private final class FakeTerminal {
    let inbox: Inbox
    private let process = Process()
    private let testbed: ClaudeTestbed
    private let config: URL
    private let sessionID = UUID().uuidString.lowercased()

    init(_ testbed: ClaudeTestbed, config: URL, status: String?) throws {
        self.testbed = testbed
        self.config = config
        process.executableURL = URL(filePath: "/bin/sleep")
        process.arguments = ["60"]
        try process.run()
        inbox = try Inbox(at: testbed.root.appending(path: "inbox-\(process.processIdentifier).sock").path)  // 不放桥的连接目录：桥会去连那里的每个 socket
        var registry: [String: JSONValue] = ["pid": .number(Double(process.processIdentifier)), "sessionId": .string(sessionID)]
        if let status { registry["status"] = .string(status) }
        let sessions = config.appending(path: "sessions")
        try FileManager.default.createDirectory(at: sessions, withIntermediateDirectories: true)
        try JSONValue.object(registry).data.write(to: sessions.appending(path: "\(process.processIdentifier).json"))
    }

    deinit { process.terminate() }

    func appear() async throws -> PiSession {
        let input: JSONValue = ["hook_event_name": "SessionStart", "session_id": .string(sessionID), "cwd": .string(testbed.work.path)]
        let envelope = AgentHookEnvelope(
            agent: .claudeCode, input: input.data,
            environment: ["CLAUDE_CODE_SESSION_ID": sessionID, "CLAUDE_CODE_MESSAGING_SOCKET": inbox.path, "CLAUDE_CONFIG_DIR": config.path],
            pid: process.processIdentifier, tty: nil)
        let fd = try UnixSocket.connect(testbed.paths.pi.hookSocket.path)
        defer { close(fd) }
        let line = try JSONEncoder().encode(envelope) + Data([0x0A])
        _ = line.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return try await testbed.waitForSession(pid: process.processIdentifier)
    }

    func kill() { Darwin.kill(process.processIdentifier, SIGKILL) }
}
#endif
