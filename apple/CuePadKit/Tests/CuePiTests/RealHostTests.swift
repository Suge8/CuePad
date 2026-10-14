#if os(macOS)
import CueTestSupport
import Foundation
import Testing
import CueStore
@testable import CuePi

/// 端到端：CuePad 在后台托管 Pi（RPC 模式，没有终端界面）——恢复已结束的会话、开新会话、空闲退出、用户在别处打开同一会话时交出、
/// 不随 CuePad 结束、扩展协议变了的托管进程被换掉。
@MainActor
@Suite(RealAgents.taped(.pi), .agentTape(.pi), RealAgents.serialWhenRecording(.pi), .timeLimit(.minutes(2)))
struct RealHostTests {
    /// 先用一个普通 Pi 进程（假模型装在 agent 目录里，托管进程也加载得到）跑一轮、落盘，再结束它，留下一个已结束的会话文件。
    private func endedSession(_ pi: PiProcess, _ bridge: PiBridge) async throws -> (file: URL, sessionID: String) {
        try await eventually("桥发现会话") { !bridge.sessions.isEmpty }
        let session = bridge.sessions[0]
        try pi.prompt("第一轮")
        try await eventually("回答落盘") { recap(of: session)?.lastReply != nil }
        pi.kill(SIGTERM)
        try await eventually("会话结束") { bridge.sessions.isEmpty }
        return (try #require(session.sessionFile), session.sessionID)
    }

    /// 空闲时限给得短：测试进程意外退出时，留下的托管进程不久也会自己退。
    private func host(_ pi: PiProcess, _ bridge: PiBridge, idleLimit: Duration = .seconds(120)) -> PiHost {
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
        defer { stopHostedProcesses(bridge) }

        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi"))

        #expect(resumed.sessionID == sessionID && resumed.hosted)
        _ = try await bridge.send(PiMessage(text: "后台接着说"), to: resumed.id)
        try await eventually("后台进程回答了") { replies(in: file).last == "ECHO 后台接着说 IMAGES[]" }
    }

    /// 托管的标记只属于托管的那个 Pi：它起的子进程（Agent 的命令、里面再起的 pi）看不到 CUEPAD_HOSTED，不会也自认托管、空闲到点自己退出；
    /// 它自己 /reload 后仍是托管的。
    @Test func theHostedMarkStaysWithTheHostedProcessAndIsNotInheritedByItsChildren() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi"))
        let seen = pi.cwd.appending(path: "hosted-env.txt")

        _ = try await bridge.send(PiMessage(text: "[[tool:printf '%s' \"${CUEPAD_HOSTED-unset}\" > '\(seen.path)']] 看环境"), to: resumed.id)
        try await eventually("子进程写下了它看到的") { (try? String(contentsOf: seen, encoding: .utf8)) != nil }
        #expect(try String(contentsOf: seen, encoding: .utf8) == "unset")

        let log = ChangeLog(bridge)
        try await bridge.command("/reload", in: resumed.id)
        try await eventually("重载后重新连上") { !log.ended.isEmpty && bridge.sessions.contains { $0.sessionID == sessionID } }
        #expect(bridge.sessions.first { $0.sessionID == sessionID }?.hosted == true)
    }

    /// 结束会话：托管的进程被关掉（空闲时与正在跑一轮时一样），会话从桥上消失，是正常退出（bye quit）。
    @Test(arguments: ["", "[[slow]] 正在跑的一轮"])
    func endingAHostedSessionClosesItsProcessEvenMidTurn(prompt: String) async throws {
        AgentTape.variant(prompt.isEmpty ? "idle" : "busy")
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, _) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi"))
        if !prompt.isEmpty {
            _ = try await bridge.send(PiMessage(text: prompt), to: resumed.id)
            try await eventually("后台在忙") { busy(bridge.sessions.first { $0.id == resumed.id }?.state) }
        }
        let log = ChangeLog(bridge)

        try await host.end(resumed.id)

        #expect(bridge.sessions.isEmpty)
        try await eventually("会话结束的通知到了") { log.ended.count == 1 }
        try await eventually("日志记下了") { log.ended[0].1 == .closed(reason: "quit") }
    }

    /// 不起 Pi：桥上根本没有这个会话。
    @Test func endingASessionThatIsAlreadyGoneSucceeds() async throws {
        let root = try makeTempDirectory()
        let paths = PiPaths(agentDirectory: root.appending(path: "agent"), socketDirectory: root.appending(path: "s"), binDirectory: root.appending(path: "bin"))
        let bridge = PiBridge(socketDirectory: paths.socketDirectory)
        defer { bridge.stop() }
        try bridge.start()
        try await PiHost(bridge: bridge, paths: paths, extraArguments: PiProcess.quietArguments).end("gone.1")
    }

    @Test func aNewSessionStartsInTheBackgroundAndIsClaimedByItsToken() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }

        let opened = try await host.open(in: pi.cwd, launchToken: "tok-1", executable: AgentTape.active.executable("pi"))

        #expect(opened.launchToken == "tok-1" && opened.hosted)
        _ = try await bridge.send(PiMessage(text: "开场的话"), to: opened.id)
        try await eventually("回答了开场的话") {
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
        defer { stopHostedProcesses(bridge) }

        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi"))

        try await eventually("空闲到点后退出") { !bridge.sessions.contains { $0.id == resumed.id } }
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
        defer { stopHostedProcesses(bridge) }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi"))

        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }

        try await eventually("后台进程让出") {
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
        defer { stopHostedProcesses(bridge) }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi"))
        _ = try await bridge.send(PiMessage(text: "[[slow]] 后台这一轮"), to: resumed.id)
        try await eventually("后台在忙") { busy(bridge.sessions.first { $0.id == resumed.id }?.state) }

        let log = ChangeLog(bridge)
        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }

        try await eventually("用户的进程连上") { bridge.sessions.contains { $0.pid == mine.pid } }
        try pi.release()  // 后台这一轮这才做完（它停在假模型里，由测试放行）

        // 重新载入时用户那个进程的会话先结束再出现：第二次出现就是读到了后台那一轮
        try await eventually("后台做完退出、用户的进程重新载入") {
            bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [mine.pid]
                && log.changes.count { if case .appeared(let s) = $0 { s.pid == mine.pid } else { false } } >= 2
        }
        try mine.prompt("我接着说")
        try await eventually("用户这句落盘") { entries(in: file).contains { $0.role == "user" && $0.text == "我接着说" } }
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
        defer { stopHostedProcesses(bridge) }
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi"))
        _ = try await bridge.send(PiMessage(text: "[[slow]] 后台这一轮"), to: resumed.id)
        try await eventually("后台在忙") { busy(bridge.sessions.first { $0.id == resumed.id }?.state) }

        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }
        try await eventually("用户的进程连上") { bridge.sessions.contains { $0.pid == mine.pid } }
        try mine.prompt("我自己的")
        try await eventually("用户这句落盘") { entries(in: file).contains { $0.role == "user" && $0.text == "我自己的" } }
        try pi.release()  // 用户先写了：后台这一轮这才做完

        _ = try await mine.waitForEvent("提示会话分出了支线") {
            $0["method"] as? String == "notify" && ($0["message"] as? String)?.contains("支线") == true
        }
        #expect(bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [mine.pid])
    }

    /// 托管的进程不随 CuePad 结束：发出一轮后 CuePad 这一侧整个没了（桥与托管服务都停掉，相当于 App 退出），这一轮照常跑完；
    /// 新起的一套桥重新连上，看到同一个进程、标着托管、状态是做完了。
    @Test func aHostedSessionOutlivesCuePadAndIsSeenAgainByTheNextOne() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let first = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { pi.stop() }
        try first.start()
        var host: PiHost? = host(pi, first)
        host?.start()
        let opened = try #require(try await host?.open(in: pi.cwd, launchToken: "tok-outlive", executable: AgentTape.active.executable("pi")))
        _ = try await first.send(PiMessage(text: "[[slow]] 跑到一半 CuePad 退出"), to: opened.id)
        try await eventually("后台在忙") { busy(first.sessions.first { $0.id == opened.id }?.state) }

        host = nil
        first.stop()
        try pi.release()

        let next = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { stopHostedProcesses(next); next.stop() }
        try next.start()
        try await eventually("新的桥看到它做完了这一轮") {
            next.sessions.first { $0.pid == opened.pid }.map { $0.hosted && $0.state == .settled } == true
        }
        #expect(recap(of: next.sessions.first { $0.pid == opened.pid })?.lastReply?.contains("跑到一半") == true)
    }

    /// App 更新后扩展协议号变了：还在跑旧扩展的托管进程没有终端能 /reload，CuePad 让它退出；下次发消息用新扩展恢复，话送达。
    /// 上一版 App 托管的进程在跑旧协议的扩展（App 更新了）：新 App 一看到就让它退出，下次发话用新扩展恢复。
    @Test func anIncompatibleHostedProcessIsToldToExitAndTheNextMessageResumesIt() async throws {
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let installed = pi.paths.extensionsDirectory.appending(path: "cuepad-bridge.ts")
        let current = try String(contentsOf: installed, encoding: .utf8)
        try OldExtension.otherProtocol.rewrite(current).write(to: installed, atomically: true, encoding: .utf8)
        let left = try await PiProcess(alongside: pi, sessionFile: file, env: [PiHost.hostedVariable: "120"])
        defer { left.stop() }
        try await eventually("旧扩展的托管进程在桥上") { bridge.sessions.contains { $0.sessionID == sessionID && $0.state == .incompatible && $0.hosted } }
        try current.write(to: installed, atomically: true, encoding: .utf8)  // 新 App 装好了新扩展

        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }

        try await eventually("旧扩展的托管进程退出了") { !bridge.sessions.contains { $0.sessionID == sessionID } }
        await left.waitUntilExit()
        let resumed = try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi"))
        #expect(resumed.sessionID == sessionID && resumed.state != .incompatible)
        _ = try await bridge.send(PiMessage(text: "换上新扩展之后"), to: resumed.id)
        try await eventually("话送达、有回答") { replies(in: file).last == "ECHO 换上新扩展之后 IMAGES[]" }
    }

    /// 磁盘上的扩展不是随包版本（接入没修好）：托管启动起出的进程读不懂托管约定，既不会空闲自退、CuePad 也不认它——
    /// 启动报错，进程退出，不留孤儿。
    @Test(arguments: OldExtension.allCases)
    func aHostedLaunchOnAnExtensionThatCannotHonorHostingIsStoppedAndReported(_ old: OldExtension) async throws {
        AgentTape.variant("\(old)")
        let pi = try await PiProcess(modelInAgentDirectory: true)
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let installed = pi.paths.extensionsDirectory.appending(path: "cuepad-bridge.ts")
        try old.rewrite(String(contentsOf: installed, encoding: .utf8)).write(to: installed, atomically: true, encoding: .utf8)
        let host = host(pi, bridge)
        host.start()
        let changes = bridge.changes()

        await #expect(throws: PiHostError.extensionMismatch) { try await host.resume(sessionFile: file, in: pi.cwd, executable: AgentTape.active.executable("pi")) }

        var launched: Int32?
        for await change in changes {
            if case .appeared(let session) = change, session.sessionID == sessionID { launched = session.pid; break }
        }
        let pid = try #require(launched)
        defer { kill(pid, SIGTERM) }  // 见红时别留下
        try await eventually("起出的进程退出了") { kill(pid, 0) != 0 }
    }

    /// 读不懂托管约定的旧扩展：协议号不同的，与把 `CUEPAD_HOSTED` 当作 "1" 来认的（协议号没变）。
    enum OldExtension: CaseIterable, Sendable {
        case otherProtocol, oldHostedValue

        func rewrite(_ source: String) -> String {
            switch self {
            case .otherProtocol: source.replacing(/const PROTOCOL_VERSION = \d+;/, with: "const PROTOCOL_VERSION = 1;")
            case .oldHostedValue: source.replacing(/const IS_HOSTED = .*;/, with: "const IS_HOSTED = process.env[HOSTED_ENV] === \"1\";")
            }
        }
    }
}
#endif
