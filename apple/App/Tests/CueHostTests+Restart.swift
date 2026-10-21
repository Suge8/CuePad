#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Darwin
import Foundation
import Network
import Synchronization
import Testing
@testable import CuePad

extension CueHostTests {
    @Test func 一轮中途被杀_你的话重新交出() async throws {
        let rig = try await Rig()
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("请慢慢想")
        try await eventually("交给了大脑") { try await rig.store.cueMessagesToDeliver().isEmpty }
        try await eventually("请求挂在模型那里") { rig.model.hanging }
        kill(first, SIGKILL)
        try await rig.message(.cue, containing: "收到：请慢慢想")
        #expect(!rig.brainPIDs.contains(first))
        await rig.stop()
    }

    /// 一件事分三步同时做、各开着会话：Cue 的信封里三步都在（不只当前那一步）；其中一步的会话做到一半断开（进程没了，
    /// 重启、更新、崩溃都是这样），Cue 醒来看到的是它被打断了，不是歇着。
    @Test func 并行的三步都在信封里_做到一半断开的显示被打断() async throws {
        let rig = try await Rig()
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("三步并行", in: project.id)
        let titles = ["会话绑定多任务", "提示音和提示窗", "账号配额"]
        var sessions: [FakeExtension] = []
        for (index, title) in titles.enumerated() {
            let step = try await store.createTask(title, under: task.id)
            let file = rig.folder.appending(path: "s\(index).jsonl")
            try Data("{}\n".utf8).write(to: file)
            // 先绑上再连上（同从任务开会话）：会话一出现就在这一步下
            try await store.linkCard(step.id, toSession: "s\(index)")
            sessions.append(try await rig.app.host.connect("s\(index)", cwd: rig.folder.path, busy: true, sessionFile: file.path))
        }
        try await eventually("三个会话都记下在干活") { try await store.allPiSessionStates().filter { $0.state.isWorking }.count == 3 }

        try await rig.say("念一下看板")
        let board = try await rig.message(.cue, containing: "看板：")
        for title in titles { #expect(board.text.contains(title), "信封里有「\(title)」") }

        sessions[1].crash()
        let after = try await rig.message(.cue, containing: "被打断")
        let lines = after.text.split(separator: "\n")
        #expect(lines.first { $0.contains("提示音和提示窗") }?.contains("被打断") == true)
        #expect(lines.filter { $0.contains("被打断") }.count == 1)
        for title in [titles[0], titles[2]] { #expect(lines.first { $0.contains(title) }?.contains("工作中") == true) }
        await rig.stop()
    }

    /// 重启 CuePad 时托管的会话还在跑（它不随 App 退出）：启动对账不把它记为被打断，Cue 看到的仍是工作中。
    /// 刚升级、还没记下进程的会话（升级前写的记录）不知道还在不在，原样不动：仍是工作中，说明与子代理都在，不写成歇着或被打断。
    @Test func 重启时还活着的托管会话不算被打断() async throws {
        let rig = try await Rig()
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("三步并行 托管着", in: project.id)
        let running = try await store.createTask("托管着在跑", under: task.id), upgraded = try await store.createTask("升级前就在跑", under: task.id)
        let file = rig.folder.appending(path: "h0.jsonl")
        try Data("{}\n".utf8).write(to: file)
        _ = try await rig.app.host.connect("h0", cwd: rig.folder.path, busy: true, hosted: true, sessionFile: file.path)
        try await store.linkCard(running.id, toSession: "h0")
        // 升级前写的记录：在跑、托管的，本机没有它的进程
        let helper = PiSubagentState(name: "helper", role: "工程师", phase: .known(.running))
        try await PiStateRecorder(store: store, hostID: TestApp.hostID)
            .update(sessionID: "h1", state: .tool, detail: "bash · swift test", hosted: true, subagents: [helper])
        try await store.linkCard(upgraded.id, toSession: "h1")
        try await eventually("记下在干活") { try await store.allPiSessionStates().filter { $0.state.isWorking }.count == 2 }

        try await rig.services.resetPiState()  // 启动对账：桥上的托管会话还连着，它的进程还在
        let states = Dictionary(uniqueKeysWithValues: try await store.allPiSessionStates().map { ($0.sessionID, $0) })
        #expect(states["h0"]?.state == .known(.thinking))
        #expect(states["h1"]?.state == .known(.tool) && states["h1"]?.detail == "bash · swift test" && states["h1"]?.subagents == [helper])
        try await rig.say("念一下看板")
        let board = try await rig.message(.cue, containing: "看板：")
        let lines = board.text.split(separator: "\n")
        for step in ["托管着在跑", "升级前就在跑"] { #expect(lines.first { $0.contains(step) }?.contains("工作中") == true, "\(step)") }
        #expect(!board.text.contains("被打断") && !board.text.contains("歇着"))
        await rig.stop()
    }

    /// 上下文到了换新线（刚启用那一轮就用到了）：下一次醒来提示先写交接；交接写好、这一轮结束后换新班次，第一轮带着交接醒来。
    @Test func 写交接后新班次接上() async throws {
        let rig = try await Rig(usage: 70_000)
        let first = try #require(rig.brainPIDs.first)
        try await rig.say("第一句")
        try await rig.message(.handoff, containing: "交接：在跟登录页")
        try await rig.message(.cue, containing: "接上了：交接：在跟登录页")  // 写下交接的那一轮是你发起的：换新后照样给你看
        #expect(rig.brainPIDs.count == 1 && rig.brainPIDs.first != first)
        await rig.stop()
    }
}
#endif
