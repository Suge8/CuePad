#if os(macOS)
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 终端里的 Claude Code 起好之前（登记文件里没有 `status`）CuePad 不往它的收件箱送话；一直起不好就报没发出，起好了再发就送到。
@MainActor
struct ClaudeTerminalReadyTests {
    @Test func aMessageToATerminalSessionThatNeverGetsReadyIsNotSent() async throws {
        let directory = URL(filePath: "/tmp/cpr-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = directory.appending(path: "registry.json")
        try Data(#"{"pid": 1}"#.utf8).write(to: registry)
        let inbox = directory.appending(path: "inbox.sock").path
        let listener = try UnixSocket.listen(inbox)
        defer { close(listener) }
        func knocked() -> Bool {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            return poll(&waiting, 1, 0) == 1
        }

        let clock = ManualTiming()
        let terminal = ClaudeTerminalSession(
            id: "t", pid: getpid(), bridge: PiBridge(socketDirectory: directory), gate: PresenceGate(presence: TestPresence()),
            inbox: inbox, registry: registry, timing: clock.timing, runningSince: nil, waiting: false)
        let sending = Task { try await terminal.send(PiMessage(text: "你好"), in: "t") }
        try await eventually("在等它起好，或已经送了") { clock.sleeperCount > 0 || knocked() }
        clock.advance(AgentTimeouts.terminalReady)
        await #expect(throws: PiBridgeError.rejected("not_ready")) { try await sending.value }
        #expect(!knocked(), "没起好时收件箱里不该有话")

        try Data(#"{"pid": 1, "status": "idle"}"#.utf8).write(to: registry, options: .atomic)
        try await terminal.send(PiMessage(text: "你好"), in: "t")
        #expect(knocked())
    }
}
#endif
