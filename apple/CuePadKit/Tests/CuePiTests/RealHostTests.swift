#if os(macOS)
import Foundation
import Testing
@testable import CuePi

/// 端到端：CuePad 在后台托管 Pi（RPC 模式，没有终端界面）——恢复已结束的会话、开新会话、空闲退出、用户在别处打开同一会话时交出。
@MainActor
@Suite(.enabled(if: realPiAvailable, "需要 ~/.local/bin/pi"), .timeLimit(.minutes(2)))
struct RealHostTests {
    /// 先用一个普通 Pi 进程（假模型装在 agent 目录里，托管进程也加载得到）跑一轮、落盘，再结束它，留下一个已结束的会话文件。
    private func endedSession(_ pi: PiProcess, _ bridge: PiBridge) async throws -> (file: URL, sessionID: String) {
        try await eventually("桥发现会话", timeout: .seconds(20)) { !bridge.sessions.isEmpty }
        let session = bridge.sessions[0]
        try pi.prompt("第一轮")
        try await eventually("回答落盘", timeout: .seconds(20)) { bridge.sessions.first?.lastReply != nil }
        pi.kill(SIGTERM)
        try await eventually("会话结束", timeout: .seconds(20)) { bridge.sessions.isEmpty }
        return (try #require(session.sessionFile), session.sessionID)
    }

    private func host(_ pi: PiProcess, _ bridge: PiBridge, idleLimit: Duration = .seconds(1800)) -> PiHost {
        PiHost(bridge: bridge, paths: pi.paths, idleLimit: idleLimit, extraArguments: PiProcess.quietArguments)
    }

    private func replies(in file: URL) -> [String] {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let message = object["message"] as? [String: Any], message["role"] as? String == "assistant",
                  let blocks = message["content"] as? [[String: Any]] else { return nil }
            return blocks.compactMap { $0["text"] as? String }.joined()
        }
    }

    @Test func anEndedSessionIsResumedInTheBackgroundAndTheMessageArrives() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { host.closeAll() }

        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: realPiURL)

        #expect(resumed.sessionID == sessionID && resumed.hosted)
        _ = try await bridge.send(PiMessage(text: "后台接着说"), to: resumed.id)
        try await eventually("后台进程回答了", timeout: .seconds(20)) { replies(in: file).last == "ECHO 后台接着说 IMAGES[]" }
    }

    @Test func aNewSessionStartsInTheBackgroundAndIsClaimedByItsToken() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        host.start()
        defer { host.closeAll() }

        let opened = try await host.open(in: pi.cwd, launchToken: "tok-1", executable: realPiURL)

        #expect(opened.launchToken == "tok-1" && opened.hosted)
        _ = try await bridge.send(PiMessage(text: "开场的话"), to: opened.id)
        try await eventually("回答了开场的话", timeout: .seconds(20)) {
            bridge.sessions.first { $0.id == opened.id }?.lastReply == "ECHO 开场的话 IMAGES[]"
        }
    }

    @Test func anIdleHostedSessionExitsAfterTheIdleLimit() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, _) = try await endedSession(pi, bridge)
        let host = host(pi, bridge, idleLimit: .seconds(1))
        host.start()
        defer { host.closeAll() }

        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: realPiURL)

        try await eventually("空闲到点后退出", timeout: .seconds(20)) { !bridge.sessions.contains { $0.id == resumed.id } }
    }

    /// 后台托管着时，用户在自己的终端里打开同一个会话（同一会话 id 的新进程连上）：后台进程收尾退出，只剩用户那个。
    @Test func theHostedProcessGivesWayWhenTheSameSessionIsOpenedElsewhere() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { host.closeAll() }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: realPiURL)

        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }

        try await eventually("后台进程让出", timeout: .seconds(20)) {
            bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [mine.pid]
        }
        #expect(!bridge.sessions.contains { $0.id == resumed.id })
    }
}
#endif
