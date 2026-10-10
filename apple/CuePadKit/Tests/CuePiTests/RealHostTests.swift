#if os(macOS)
import Foundation
import Testing
import CueStore
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
        try await eventually("回答落盘", timeout: .seconds(20)) { recap(of: session)?.lastReply != nil }
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

    /// 结束会话：托管的进程被关掉（空闲时与正在跑一轮时一样），会话从桥上消失，是正常退出（bye quit）。
    @Test(arguments: ["", "[[slow]] 正在跑的一轮"])
    func endingAHostedSessionClosesItsProcessEvenMidTurn(prompt: String) async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, _) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { host.closeAll() }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: realPiURL)
        if !prompt.isEmpty {
            _ = try await bridge.send(PiMessage(text: prompt), to: resumed.id)
            try await eventually("后台在忙", timeout: .seconds(10)) { busy(bridge.sessions.first { $0.id == resumed.id }?.state) }
        }
        let log = ChangeLog(bridge)

        try await host.end(resumed.id)

        #expect(bridge.sessions.isEmpty)
        try await eventually("会话结束的通知到了", timeout: .seconds(5)) { log.ended.count == 1 }
        #expect(log.ended[0].1 == .closed(reason: "quit"))
    }

    @Test func endingASessionThatIsAlreadyGoneSucceeds() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        try await host.end("gone.1")
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
            recap(of: bridge.sessions.first { $0.id == opened.id })?.lastReply == "ECHO 开场的话 IMAGES[]"
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

    private func busy(_ state: PiWorkState?) -> Bool { state?.isWorking == true }

    /// 会话文件里的条目（跳过文件头）：id、上一条、角色、文字。
    private func entries(in file: URL) -> [(id: String, parent: String?, role: String?, text: String)] {
        let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { line in
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = object["id"] as? String, object["type"] as? String != "session" else { return nil }
            let message = object["message"] as? [String: Any]
            let blocks = message?["content"] as? [[String: Any]] ?? []
            let body = (message?["content"] as? String) ?? blocks.compactMap { $0["text"] as? String }.joined()
            return (id, object["parentId"] as? String, message?["role"] as? String, body)
        }
    }

    /// 后台进程正在跑一轮时用户打开了同一会话：后台做完这一轮再退；用户那个进程这期间没写过，就把会话重新载入到最新——
    /// 接着说的话接在后台那一轮的回答后面，不分支。
    @Test func aBusyHandoffReloadsTheUsersProcessSoTheSessionDoesNotBranch() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { host.closeAll() }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: realPiURL)
        _ = try await bridge.send(PiMessage(text: "[[slow]] 后台这一轮"), to: resumed.id)
        try await eventually("后台在忙", timeout: .seconds(10)) { busy(bridge.sessions.first { $0.id == resumed.id }?.state) }

        let log = ChangeLog(bridge)
        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }

        // 重新载入时用户那个进程的会话先结束再出现：第二次出现就是读到了后台那一轮
        try await eventually("后台做完退出、用户的进程重新载入", timeout: .seconds(20)) {
            bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [mine.pid]
                && log.changes.count { if case .appeared(let s) = $0 { s.pid == mine.pid } else { false } } >= 2
        }
        try mine.prompt("我接着说")
        try await eventually("用户这句落盘", timeout: .seconds(20)) { entries(in: file).contains { $0.role == "user" && $0.text == "我接着说" } }
        let all = entries(in: file)
        let backgroundReply = try #require(all.last { $0.role == "assistant" && $0.text.contains("后台这一轮") })
        let mineEntry = try #require(all.first { $0.role == "user" && $0.text == "我接着说" })
        #expect(mineEntry.parent == backgroundReply.id)
    }

    /// 同上，但用户那个进程在后台做完之前已经说了话（会话已分出支线）：不重新载入，在用户的会话里提示一句。
    @Test func aBusyHandoffLeavesTheUsersProcessAloneOnceItHasWrittenAndSaysSo() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { host.closeAll() }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: realPiURL)
        _ = try await bridge.send(PiMessage(text: "[[slow]] 后台这一轮"), to: resumed.id)
        try await eventually("后台在忙", timeout: .seconds(10)) { busy(bridge.sessions.first { $0.id == resumed.id }?.state) }

        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }
        try await eventually("用户的进程连上", timeout: .seconds(20)) { bridge.sessions.contains { $0.pid == mine.pid } }
        try mine.prompt("我自己的")

        _ = try await mine.waitForEvent("提示会话分出了支线") {
            $0["method"] as? String == "notify" && ($0["message"] as? String)?.contains("支线") == true
        }
        #expect(bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [mine.pid])
    }
}
#endif
