#if os(macOS)
import CueTestSupport
import Darwin
import Foundation
import Testing
import CueStore
@testable import CuePi

@MainActor
@Suite(RealAgents.needs(.pi), RealAgents.tiered)
struct RealHostTests {
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
    private func host(_ pi: PiProcess, _ bridge: PiBridge, idleLimit: Duration = .seconds(120)) -> PiRuntime {
        PiRuntime(bridge: bridge, paths: pi.paths, pi: { pinnedPi.executable }, idleLimit: idleLimit, timing: noDeadline)
    }

    private func resume(_ host: PiRuntime, _ file: URL, in pi: PiProcess, on bridge: PiBridge) async throws -> PiSession {
        let id = try await host.resume(IndexedSession(id: "", path: file.path, cwd: pi.cwd.path, lastActivityAt: .now))
        return try #require(bridge.session(id: id))
    }

    @Test(.tags(.smoke)) func anEndedSessionIsResumedInTheBackgroundAndTheMessageArrives() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }

        let resumed = try await resume(host, file, in: pi, on: bridge)

        #expect(resumed.sessionID == sessionID && resumed.hosted)
        try await bridge.send(PiMessage(text: "后台接着说"), to: resumed.id)
        try await eventually("后台进程回答了") { fileTexts("assistant", in: file).last == "ECHO 后台接着说" }
    }

    /// 同 `RealHostedResumeTests` 的并发恢复：同一会话同时来两次恢复，只起一个 Pi，两边拿到同一个 id。
    @Test func twoResumesOfTheSameSessionAtOnceStartOneProcess() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }

        async let one = resume(host, file, in: pi, on: bridge)
        async let two = resume(host, file, in: pi, on: bridge)
        let (a, b) = try await (one, two)

        #expect(a.id == b.id)
        #expect(bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [a.pid])
    }

    @Test func theHostedMarkStaysWithTheHostedProcessAndIsNotInheritedByItsChildren() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        let resumed = try await resume(host, file, in: pi, on: bridge)
        let seen = pi.cwd.appending(path: "hosted-env.txt")

        pi.model.on("看环境", .call("bash", ["command": "printf '%s' \"${CUEPAD_HOSTED-unset}\" > '\(seen.path)'"]), .say("TOOL_DONE"))
        try await bridge.send(PiMessage(text: "看环境"), to: resumed.id)
        // `>` 先建出空文件、printf 才写进去：等到有内容
        try await eventually("子进程写下了它看到的") { (try? String(contentsOf: seen, encoding: .utf8))?.isEmpty == false }
        #expect(try String(contentsOf: seen, encoding: .utf8) == "unset")

        let log = ChangeLog(bridge)
        try await bridge.command("/reload", in: resumed.id)
        try await eventually("重载后重新连上") { !log.ended.isEmpty && bridge.sessions.contains { $0.sessionID == sessionID } }
        #expect(bridge.sessions.first { $0.sessionID == sessionID }?.hosted == true)
    }

    @Test func aNewSessionStartsInTheBackgroundAndIsClaimedByItsToken() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }

        let opened = try #require(bridge.session(id: try await host.open(in: pi.cwd, launchToken: "tok-1", name: nil, model: nil, thinking: nil)))

        #expect(opened.launchToken == "tok-1" && opened.hosted)
        try await bridge.send(PiMessage(text: "开场的话"), to: opened.id)
        try await eventually("回答了开场的话") {
            recap(of: bridge.sessions.first { $0.id == opened.id })?.lastReply == "ECHO 开场的话"
        }
    }

    /// 忙时点结束（同 `RealHostedEndTests` 的第一例）：扩展先中止这一轮、Pi 自己把它写成被停下的一轮，再退出，结束报成功。
    @Test func endingABusyHostedSessionStopsTheTurnBeforeItQuits() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        pi.model.on("BUSY-HANG", .stream(["Working on it"]))
        let session = try #require(bridge.session(id: try await host.open(in: pi.cwd, launchToken: "tok-busy", name: nil, model: nil, thinking: nil)))
        try await bridge.send(PiMessage(text: "BUSY-HANG keep going"), to: session.id)
        try await eventually("这一轮在跑、停在模型里") { bridge.session(id: session.id)?.state.isWorking == true }

        try await bridge.end(session.id)
        #expect(bridge.session(id: session.id) == nil)
        try await eventually("进程退了") { kill(session.pid, 0) != 0 }
        let record = try PiHistory.index(file: try #require(session.sessionFile), agent: .pi, from: nil, files: scratchFiles)
        #expect(record.messages.contains { $0.role == .known(.user) && $0.text.contains("BUSY-HANG") })
        #expect(record.checkpoint.stoppedAt != nil, "会话记录里没有被停下的这一轮：\(record.messages.map(\.text))")
    }

    /// 起来马上点结束、说出第一句马上点停止或结束（同 `RealHostedEndTests` 的那一例，#81）：都不等满 `AgentTimeouts.stop`。
    @Test(arguments: ["end on open", "stop on first message", "end on first message"])
    func stoppingOrEndingRightAwayDoesNotWaitOutTheStopLimit(_ moment: String) async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        pi.model.on("BUSY-HANG", .stream(["Working on it"]))
        let session = try #require(bridge.session(id: try await host.open(in: pi.cwd, launchToken: "tok-now", name: nil, model: nil, thinking: nil)))
        if moment != "end on open" { try await bridge.send(PiMessage(text: "BUSY-HANG keep going"), to: session.id) }
        let began = ContinuousClock.now
        if moment == "stop on first message" {
            try await bridge.abort(session.id)
            try await eventually("停下了") { bridge.session(id: session.id)?.state == .settled }
        } else {
            try await bridge.end(session.id)
            try await eventually("进程退了") { kill(session.pid, 0) != 0 }
        }
        let took = began.duration(to: .now)
        #expect(took < .seconds(10), "用了 \(took)")
    }

    @Test func anIdleHostedSessionExitsAfterTheIdleLimit() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, _) = try await endedSession(pi, bridge)
        let host = host(pi, bridge, idleLimit: .seconds(1))
        host.start()
        defer { stopHostedProcesses(bridge) }

        // 上了桥才返回；空闲时限只有 1 秒，返回时它可能已经退了，所以不再查它在不在
        let id = try await host.resume(IndexedSession(id: "", path: file.path, cwd: pi.cwd.path, lastActivityAt: .now))

        try await eventually("空闲到点后退出") { bridge.session(id: id) == nil }
    }

    @Test func theHostedProcessGivesWayWhenTheSameSessionIsOpenedElsewhere() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        let resumed = try await resume(host, file, in: pi, on: bridge)

        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }

        try await eventually("后台进程让出") {
            bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [mine.pid]
        }
        #expect(!bridge.sessions.contains { $0.id == resumed.id })
    }

    private func busy(_ state: PiWorkState?) -> Bool { state?.isWorking == true }

    @Test func aBusyHandoffReloadsTheUsersProcessSoTheSessionDoesNotBranch() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        let resumed = try await resume(host, file, in: pi, on: bridge)
        let gate = pi.hold("后台这一轮")
        try await bridge.send(PiMessage(text: "后台这一轮"), to: resumed.id)
        try await eventually("后台在忙") { busy(bridge.sessions.first { $0.id == resumed.id }?.state) }

        let log = ChangeLog(bridge)
        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }

        try await eventually("用户的进程连上") { bridge.sessions.contains { $0.pid == mine.pid } }
        gate.open()  // 后台这一轮这才做完（它停在假模型里，由测试放行）

        try await eventually("后台做完退出、用户的进程重新载入") {
            bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [mine.pid]
                && log.changes.count { if case .appeared(let s) = $0 { s.pid == mine.pid } else { false } } >= 2
        }
        try mine.prompt("我接着说")
        try await eventually("用户这句落盘") { fileMessages(in: file).contains { $0.role == "user" && $0.text == "我接着说" } }
        let all = fileMessages(in: file)
        let backgroundReply = try #require(all.last { $0.role == "assistant" && $0.text.contains("后台这一轮") })
        let mineEntry = try #require(all.first { $0.role == "user" && $0.text == "我接着说" })
        #expect(mineEntry.parent == backgroundReply.id)
    }

    @Test func aBusyHandoffLeavesTheUsersProcessAloneOnceItHasWrittenAndSaysSo() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        let resumed = try await resume(host, file, in: pi, on: bridge)
        let gate = pi.hold("后台这一轮")
        try await bridge.send(PiMessage(text: "后台这一轮"), to: resumed.id)
        try await eventually("后台在忙") { busy(bridge.sessions.first { $0.id == resumed.id }?.state) }

        let mine = try await PiProcess(alongside: pi, sessionFile: file)
        defer { mine.stop() }
        try await eventually("用户的进程连上") { bridge.sessions.contains { $0.pid == mine.pid } }
        try mine.prompt("我自己的")
        try await eventually("用户这句落盘") { fileMessages(in: file).contains { $0.role == "user" && $0.text == "我自己的" } }
        gate.open()  // 用户先写了：后台这一轮这才做完

        _ = try await mine.waitForEvent("提示会话分出了支线") {
            $0["method"] as? String == "notify" && ($0["message"] as? String)?.contains("支线") == true
        }
        #expect(bridge.sessions.filter { $0.sessionID == sessionID }.map(\.pid) == [mine.pid])
    }

    @Test func aHostedSessionOutlivesCuePadAndIsSeenAgainByTheNextOne() async throws {
        let pi = try await PiProcess()
        let first = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { pi.stop() }
        try first.start()
        var host: PiRuntime? = host(pi, first)
        host?.start()
        let openedID = try #require(try await host?.open(in: pi.cwd, launchToken: "tok-outlive", name: nil, model: nil, thinking: nil))
        let opened = try #require(first.session(id: openedID))
        let gate = pi.hold("跑到一半 CuePad 退出")
        try await first.send(PiMessage(text: "跑到一半 CuePad 退出"), to: opened.id)
        try await eventually("后台在忙") { busy(first.sessions.first { $0.id == opened.id }?.state) }

        host = nil
        first.stop()
        gate.open()

        let next = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { stopHostedProcesses(next); next.stop() }
        try next.start()
        try await eventually("新的桥看到它做完了这一轮") {
            next.sessions.first { $0.pid == opened.pid }.map { $0.hosted && $0.state == .settled } == true
        }
        #expect(first.sessions.isEmpty)
        let again = try #require(next.sessions.first { $0.pid == opened.pid })
        #expect(recap(of: again)?.lastReply?.contains("跑到一半") == true)
        try await next.send(PiMessage(text: "新的 CuePad 认回之后"), to: again.id)
        let file = try #require(again.sessionFile)
        try await eventually("认回的进程接着收话、有回答") { fileTexts("assistant", in: file).last == "ECHO 新的 CuePad 认回之后" }
    }

    @Test func anOldHostedProcessComesBackOnTheNewExtension() async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let installed = PiExtensionFiles(extensionsDirectory: pi.paths.extensionsDirectory)
        try OldExtension.unreadable.rewrite(in: installed.directory)
        let log = ChangeLog(bridge)
        let left = try await PiProcess(alongside: pi, sessionFile: file, env: [PiRuntime.hostedVariable: "120"])
        defer { left.stop() }
        try await eventually("旧扩展的托管进程上了桥") {
            log.changes.contains { if case .appeared(let s) = $0 { s.sessionID == sessionID && s.upgrading && s.hosted } else { false } }
        }

        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        try await installed.install(command: "")  // 新 App 装好了新扩展，请连着的会话换上（App 里经 `AgentIntegrations.installed`）
        bridge.offerExtensionUpgrade()

        try await eventually("同一个进程换上新扩展、重新连上") {
            bridge.sessions.contains { $0.pid == left.pid && !$0.upgrading && $0.state == .settled }
        }
        let target = try #require(bridge.sessions.first { $0.pid == left.pid })
        #expect(target.sessionID == sessionID)
        try await bridge.send(PiMessage(text: "换上新扩展之后"), to: target.id)
        try await eventually("话送达、有回答") { fileTexts("assistant", in: file).last == "ECHO 换上新扩展之后" }
    }

    @Test(arguments: OldExtension.allCases)
    func aHostedLaunchOnAnExtensionThatCannotHonorHostingIsStoppedAndReported(_ old: OldExtension) async throws {
        let pi = try await PiProcess()
        let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        try old.rewrite(in: pi.paths.extensionsDirectory.appending(path: "cuepad-bridge"))
        let host = host(pi, bridge)
        host.start()
        let changes = bridge.changes()

        await #expect(throws: PiHostError.extensionMismatch) { try await resume(host, file, in: pi, on: bridge) }

        var launched: Int32?
        for await change in changes {
            if case .appeared(let session) = change, session.sessionID == sessionID { launched = session.pid; break }
        }
        let pid = try #require(launched)
        defer { kill(pid, SIGTERM) }  // 见红时别留下
        try await eventually("起出的进程退出了") { kill(pid, 0) != 0 }
    }
}
#endif
