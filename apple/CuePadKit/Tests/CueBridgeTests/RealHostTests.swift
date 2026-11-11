#if os(macOS)
import CueTestSupport
import Darwin
import Foundation
import Testing
import CueStore
@testable import CueBridge

@MainActor
@Suite(RealAgents.needs(.pi), RealAgents.tiered)
struct RealHostTests {
    private func endedSession(_ pi: PiProcess, _ bridge: Bridge) async throws -> (file: URL, sessionID: String) {
        try await eventually("桥发现会话") { !bridge.sessions.isEmpty }
        let session = bridge.sessions[0]
        try pi.prompt("第一轮")
        try await eventually("回答落盘") { recap(of: session)?.lastReply != nil }
        pi.kill(SIGTERM)
        try await eventually("会话结束") { bridge.sessions.isEmpty }
        return (try #require(session.sessionFile), session.sessionID)
    }

    /// 空闲时限给得短：测试进程意外退出时，留下的托管进程不久也会自己退。
    private func host(_ pi: PiProcess, _ bridge: Bridge, idleLimit: Duration = .seconds(120)) -> PiRuntime {
        PiRuntime(bridge: bridge, paths: pi.paths, cleansInstalledExtension: true, pi: { pinnedPi.executable }, idleLimit: idleLimit, timing: noDeadline)
    }

    private func resume(_ host: PiRuntime, _ file: URL, in pi: PiProcess, on bridge: Bridge) async throws -> Session {
        let id = try await host.resume(IndexedSession(id: "", path: file.path, cwd: pi.cwd.path, lastActivityAt: .now))
        return try #require(bridge.session(id: id))
    }

    @Test(.tags(.smoke)) func anEndedSessionIsResumedInTheBackgroundAndTheMessageArrives() async throws {
        let pi = try await PiProcess()
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }

        let resumed = try await resume(host, file, in: pi, on: bridge)

        #expect(resumed.sessionID == sessionID)
        try await bridge.send(SessionMessage(text: "后台接着说"), to: resumed.id)
        try await eventually("后台进程回答了") { fileTexts("assistant", in: file).last == "ECHO 后台接着说" }
    }

    /// 同 `RealHostedResumeTests` 的并发恢复：同一会话同时来两次恢复，只起一个 Pi，两边拿到同一个 id。
    @Test func twoResumesOfTheSameSessionAtOnceStartOneProcess() async throws {
        let pi = try await PiProcess()
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
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
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let (file, sessionID) = try await endedSession(pi, bridge)
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        let resumed = try await resume(host, file, in: pi, on: bridge)
        let seen = pi.cwd.appending(path: "hosted-env.txt")

        pi.model.on("看环境", .call("bash", ["command": "printf '%s' \"${CUEPAD_HOSTED-unset}\" > '\(seen.path)'"]), .say("TOOL_DONE"))
        try await bridge.send(SessionMessage(text: "看环境"), to: resumed.id)
        // `>` 先建出空文件、printf 才写进去：等到有内容
        try await eventually("子进程写下了它看到的") { (try? String(contentsOf: seen, encoding: .utf8))?.isEmpty == false }
        #expect(try String(contentsOf: seen, encoding: .utf8) == "unset")

        let log = ChangeLog(bridge)
        try await bridge.command("/reload", in: resumed.id)
        try await eventually("重载后重新连上") { !log.ended.isEmpty && bridge.sessions.contains { $0.sessionID == sessionID } }
    }

    @Test func aNewSessionStartsInTheBackgroundAndIsClaimedByItsToken() async throws {
        let pi = try await PiProcess()
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }

        let opened = try #require(bridge.session(id: try await host.open(in: pi.cwd, launchToken: "tok-1", name: nil, model: nil, thinking: nil)))

        #expect(opened.launchToken == "tok-1")
        try await bridge.send(SessionMessage(text: "开场的话"), to: opened.id)
        try await eventually("回答了开场的话") {
            recap(of: bridge.sessions.first { $0.id == opened.id })?.lastReply == "ECHO 开场的话"
        }
    }

    /// 忙时点结束（同 `RealHostedEndTests` 的第一例）：扩展先中止这一轮、Pi 自己把它写成被停下的一轮，再退出，结束报成功。
    @Test func endingABusyHostedSessionStopsTheTurnBeforeItQuits() async throws {
        let pi = try await PiProcess()
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        pi.model.on("BUSY-HANG", .stream(["Working on it"]))
        let session = try #require(bridge.session(id: try await host.open(in: pi.cwd, launchToken: "tok-busy", name: nil, model: nil, thinking: nil)))
        try await bridge.send(SessionMessage(text: "BUSY-HANG keep going"), to: session.id)
        try await eventually("这一轮在跑、停在模型里") { bridge.session(id: session.id)?.state.isWorking == true }

        try await bridge.end(session.id)
        #expect(bridge.session(id: session.id) == nil)
        try await eventually("进程退了") { kill(session.pid, 0) != 0 }
        let record = try History.index(file: try #require(session.sessionFile), agent: .pi, from: nil, files: scratchFiles)
        #expect(record.messages.contains { $0.role == .known(.user) && $0.text.contains("BUSY-HANG") })
        #expect(record.messages.contains { $0.text == ChatNotice.stopped.rawValue }, "会话记录里没有被停下的这一轮：\(record.messages.map(\.text))")
    }

    /// 起来马上点结束、说出第一句马上点停止或结束（同 `RealHostedEndTests` 的那一例，#81）：都不等满 `AgentTimeouts.stop`。
    @Test(arguments: ["end on open", "stop on first message", "end on first message"])
    func stoppingOrEndingRightAwayDoesNotWaitOutTheStopLimit(_ moment: String) async throws {
        let pi = try await PiProcess()
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let host = host(pi, bridge)
        host.start()
        defer { stopHostedProcesses(bridge) }
        pi.model.on("BUSY-HANG", .stream(["Working on it"]))
        let session = try #require(bridge.session(id: try await host.open(in: pi.cwd, launchToken: "tok-now", name: nil, model: nil, thinking: nil)))
        if moment != "end on open" { try await bridge.send(SessionMessage(text: "BUSY-HANG keep going"), to: session.id) }
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

    /// 托管的 Pi 一起来就开始算闲置（扩展里，不等 CuePad 认出它）：时限 1 秒短过忙时这个测试进程认出它的用时（#166），
    /// 所以第一句经它自己的标准输入马上交出、停在假模型里，桥认出它之后才放行，闲置从这一轮歇下算起。
    @Test func anIdleHostedSessionExitsAfterTheIdleLimit() async throws {
        let pi = try await PiProcess(env: [PiRuntime.hostedVariable: "1"])
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        let gate = pi.hold("先忙着")
        try pi.prompt("先忙着")
        try await eventually("桥认出在忙的托管会话") { bridge.sessions.first.map { busy($0.state) } == true }
        let log = ChangeLog(bridge)

        gate.open()
        try await eventually("空闲到点后退出") { !log.ended.isEmpty }
        #expect(log.ended.map(\.1) == [.closed(reason: "quit")])
    }

    private func busy(_ state: WorkState?) -> Bool { state?.isWorking == true }

    @Test func aHostedSessionOutlivesCuePadAndIsSeenAgainByTheNextOne() async throws {
        let pi = try await PiProcess()
        let first = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { pi.stop() }
        try first.start()
        var host: PiRuntime? = host(pi, first)
        host?.start()
        let openedID = try #require(try await host?.open(in: pi.cwd, launchToken: "tok-outlive", name: nil, model: nil, thinking: nil))
        let opened = try #require(first.session(id: openedID))
        let gate = pi.hold("跑到一半 CuePad 退出")
        try await first.send(SessionMessage(text: "跑到一半 CuePad 退出"), to: opened.id)
        try await eventually("后台在忙") { busy(first.sessions.first { $0.id == opened.id }?.state) }

        host = nil
        first.stop()
        gate.open()

        let next = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { stopHostedProcesses(next); next.stop() }
        try next.start()
        try await eventually("新的桥看到它做完了这一轮") {
            next.sessions.first { $0.pid == opened.pid }?.state == .settled
        }
        #expect(first.sessions.isEmpty)
        let again = try #require(next.sessions.first { $0.pid == opened.pid })
        #expect(recap(of: again)?.lastReply?.contains("跑到一半") == true)
        try await next.send(SessionMessage(text: "新的 CuePad 认回之后"), to: again.id)
        let file = try #require(again.sessionFile)
        try await eventually("认回的进程接着收话、有回答") { fileTexts("assistant", in: file).last == "ECHO 新的 CuePad 认回之后" }
    }

    /// App 更新：随包的扩展目录原地换成新版（路径不变），新起的 CuePad 握手时请读不懂的旧扩展核对，它从同一路径换上新扩展、重新连回。
    @Test func anOldHostedProcessComesBackOnTheNewExtension() async throws {
        let pi = try await PiProcess()
        let old = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { old.stop(); pi.stop() }
        try old.start()
        let (file, sessionID) = try await endedSession(pi, old)
        let shipped = pi.root.appending(path: "CuePad.app/cuepad-bridge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: shipped.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: PiExtensionBundle.url, to: shipped)
        let entry = shipped.appending(path: "index.ts")
        try String(contentsOf: entry, encoding: .utf8)
            .replacing(/const EXTENSION_VERSION = \d+;/, with: "const EXTENSION_VERSION = \(PiWire.oldestExtension - 1);")
            .write(to: entry, atomically: true, encoding: .utf8)
        let log = ChangeLog(old)
        let left = try await PiProcess(bridgeExtension: shipped, alongside: pi, sessionFile: file)
        defer { left.stop() }
        try await eventually("旧扩展的托管进程上了桥") {
            log.changes.contains { if case .appeared(let s) = $0 { s.sessionID == sessionID && s.upgrading } else { false } }
        }
        old.stop()

        try FileManager.default.removeItem(at: shipped)
        try FileManager.default.copyItem(at: PiExtensionBundle.url, to: shipped)
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { stopHostedProcesses(bridge); bridge.stop() }
        try bridge.start()

        try await eventually("同一个进程换上新扩展、重新连上") {
            bridge.sessions.contains { $0.pid == left.pid && !$0.upgrading && $0.state == .settled }
        }
        let target = try #require(bridge.sessions.first { $0.pid == left.pid })
        #expect(target.sessionID == sessionID)
        try await bridge.send(SessionMessage(text: "换上新扩展之后"), to: target.id)
        try await eventually("话送达、有回答") { fileTexts("assistant", in: file).last == "ECHO 换上新扩展之后" }
    }
}
#endif
