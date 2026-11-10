#if os(macOS)
import CueStore
import CueTestSupport
import Darwin
import Foundation
import Testing
@testable import CuePad
@testable import CuePi

/// 用户验收：真实 Pi 与桥扩展执行隔离 Python 工具；只替换语音媒体与付费模型。
/// A 停止排队后，终端或同一通话开 B；旧停止必须明确结束而 B 的真实进程继续活着。
@Suite(.releasesLibraries, .pinnedPi, .serialized)
@MainActor
struct VoiceStopRaceTests {
    @Test(arguments: ["不换轮", "终端B", "语音B"])
    func 排队的停止只作用于原回合(next: String) async throws {
        let rig = try await CueHostTests.Rig(timing: { $0.sayWait = 0.1 })
        let voice = VoiceFlowFixture(rig.services)
        let process = try await agent(in: rig)
        do {
            try await exercise(next, rig: rig, voice: voice, process: process)
        } catch {
            process.end()
            _ = await process.waitForExit()
            voice.workspace.voice?.hangUp()  // 没连上通话就出错时没有它
            await rig.stop()
            throw error
        }
        process.end()
        _ = await process.waitForExit()
        try await voice.hangUp()
        await rig.stop()
    }

    private func exercise(_ next: String, rig: CueHostTests.Rig, voice: VoiceFlowFixture, process: ChildProcess) async throws {
        try await eventually("真实 Pi 连上窗口使用的桥") { rig.app.pi.sessions.contains { $0.pid == process.pid } }
        let session = try #require(rig.app.pi.sessions.first { $0.pid == process.pid })
        try await eventually("真实会话进库") { try await rig.store.allPiSessionStates().contains { $0.sessionID == session.sessionID } }
        try await voice.connect()
        let first = work("A", in: rig)
        _ = try await voice.handoff("请对隔离会话说「\(first)」")
        try await eventually("A 工具已运行且停止归属已确认") {
            FileManager.default.fileExists(atPath: rig.folder.appending(path: "A.pid").path)
                && voice.workspace.voiceExecutions.first?.state.canStop == true
        }
        let a = try pid("A", in: rig)
        await rig.services.executor.beginStop()()
        let stop = try await voice.workspace.stopVoiceExecution(session.sessionID)
        #expect(try await rig.store.deliveryRequest(stop.id)?.status == .known(.pending))
        var b: pid_t?
        if next != "不换轮" {
            let second = work("B", in: rig)
            if next == "语音B" {
                _ = try await voice.handoff("请对隔离会话说「\(second)」")
                try await eventually("同一通话的 B 投送落库") {
                    try await rig.store.deliveryRequests(toSession: session.sessionID).contains { $0.content == second }
                }
                let request = try #require(try await rig.store.deliveryRequests(toSession: session.sessionID).last { $0.content == second })
                // 另一客户端先交出 B；停止仍留在本机队列。真实消息回执负责确认这条投送，不能靠重投探测。
                try await rig.app.pi.send(PiMessage(text: second, deliveryID: request.id.uuidString), to: session.id)
                try await eventually("B 的工具归属与真实消息已关联") {
                    try await rig.store.outcome(of: request).status == .known(.succeeded)
                        && voice.workspace.voiceExecutions.contains { $0.state.sessionID == session.sessionID }
                }
            } else {
                // 另一个客户端发新用户消息，没有 Cue 的投送身份。
                try await rig.app.pi.send(PiMessage(text: second), to: session.id)
            }
            try await eventually("B 的真实工具开始工作") { FileManager.default.fileExists(atPath: rig.folder.appending(path: "B.pid").path) }
            b = try pid("B", in: rig)
            #expect(kill(try #require(b), 0) == 0)
        }
        try await rig.services.executor.start()
        try await eventually("停止请求有明确终态") {
            guard let request = try await rig.store.deliveryRequest(stop.id) else { return false }
            return [.known(.succeeded), .known(.failed)].contains(request.status)
        }
        let result = try #require(try await rig.store.deliveryRequest(stop.id))
        if next == "终端B" {
            try await eventually("停止权限消失后仍看得到动作结果") {
                voice.workspace.voiceExecutions.isEmpty && voice.workspace.voicePresentation?.executions.contains {
                    $0.id == stop.id.uuidString && $0.status.contains("不再适用")
                } == true
            }
            #expect(voice.workspace.voicePresentation?.canStopExecution == false)
            await #expect(throws: CueStoreError.self) { _ = try await voice.workspace.stopVoiceExecution(session.sessionID) }
            try await rig.store.deleteDelivery(stop.id)
            try await voice.hangUp()
            try await voice.connect()
            #expect(voice.workspace.voicePresentation?.executions.contains { $0.status.contains("不再适用") } == true)
        }
        if let b {
            #expect(result.status == .known(.failed))
            #expect(result.failure?.contains("不再适用") == true)
            #expect(kill(b, 0) == 0, "旧停止不得杀掉 B 的实际工作进程")
            if next == "语音B" {
                let own = try await voice.workspace.stopVoiceExecution(session.sessionID)
                #expect(own.id != stop.id)
                try await eventually("明确停止 B 后它才退出") {
                    try await rig.store.outcome(of: own).status == .known(.succeeded) && kill(b, 0) != 0
                }
            }
        } else {
            #expect(result.status == .known(.succeeded))
            try await eventually("A 的实际工具进程退出") { kill(a, 0) != 0 }
            try await eventually("真实状态回写停止") { voice.workspace.voiceExecutions.first?.state.canStop == false }
        }
    }

    /// 这句话的工具是一个真进程：写下自己的 pid（先写别名再改名：测试见到文件就读，直接写会读到空的），等信号或 30 秒（会话的 Pi 与大脑连同一个假模型，这条规则先于大脑的剧本认）
    private func work(_ name: String, in rig: CueHostTests.Rig) -> String {
        let command = "python3 -c 'import os,signal;open(\"\(name).tmp\",\"w\").write(str(os.getpid()));os.rename(\"\(name).tmp\",\"\(name).pid\");signal.alarm(30);signal.pause()'"
        // 只认会话收到的那句原话：大脑那边的请求里也带着它（"请对隔离会话说「WORK-A」"）
        rig.model.server.on({ $0.prompt == "WORK-\(name)" }) { $0.step == 0 ? .call("bash", ["command": command]) : .say("TOOL_DONE") }
        return "WORK-\(name)"
    }

    private func pid(_ name: String, in rig: CueHostTests.Rig) throws -> pid_t {
        try #require(pid_t(String(contentsOf: rig.folder.appending(path: "\(name).pid"), encoding: .utf8)))
    }

    private func agent(in rig: CueHostTests.Rig) async throws -> ChildProcess {
        let environment = PinnedAgent.pi.environment(home: rig.app.directory, rig.app.piPaths.launchEnvironment.merging(["PI_OFFLINE": "1"]) { $1 })
        return try await ChildProcess(realPi, ["--mode", "rpc", "--no-extensions", "-e", PiExtensionBundle.url.path,
            "--model", "fake/fake-model", "--name", "语音停止验收", "--no-skills"],
            directory: rig.folder, environment: environment, placement: .group, input: .pipe)
    }
}
#endif
