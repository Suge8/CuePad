#if os(macOS)
import CueAgent
import CueStore
import CueTestSupport
import Foundation
import SwiftUI
import Testing
@testable import CuePad

/// 会话派了子代理、自己这一轮歇下：值班的 Cue 等子代理时不被叫醒，结果交回、会话为它跑完那一轮歇下才叫醒一次；
/// 在跑的子代理太久没进展（`PiSessionState.stallAfter`）叫醒一次（真 Pi 当大脑，同 `CueHostTests`）。
/// 叫醒看的是 Mac 运行情况里的那几轮（`CueKeeper.rounds`：为什么醒、交给大脑的信封）。
@Suite(.enabled(if: FileManager.default.isExecutableFile(atPath: realPi.path), "需要 ~/.local/bin/pi"), .serialized)
@MainActor
struct SubagentWakeTests {
    /// 你请 Cue 开工；会话派出子代理、自己这一轮答完（等子代理）：Cue 不醒，你这时跟它说话，它看到的变化里也没有这个会话。
    /// 子代理交回结果、会话为它跑完一轮：歇下先到、这一轮的回答随后才写进会话文件（回答晚到）——Cue 只醒一次，信封里是那一轮的回答；
    /// 你在手机上开着这个会话看着它停下也一样：这件事是 Cue 开的。
    /// 会话文件由 Mac 照常读（不经测试代写摘要）：会话是 FireCode 的指挥官，交回结果是一条机器消息开的轮。
    @Test func 等子代理不叫醒_结果交回那一轮回答晚到也只叫醒一次() async throws {
        let rig = try await CueHostTests.Rig()
        let store = rig.store
        let workspace = Workspace(services: rig.services)
        try await say("请建个任务并开工", in: workspace, rig)
        try await eventually("开工这一轮做完") { try await store.cueState()?.state == .known(.settled) && rig.model.answered("开新会话") }
        try await eventually("执行器开出会话") { !rig.app.host.extensions.isEmpty }
        let session = try #require(rig.app.host.extensions.values.first)
        let task = try #require(try await store.cueBoard().tasks.first?.task)
        try await store.linkCard(task.id, toSession: session.sessionID)  // 认领（假扩展不带开会话的标识）
        try await store.updateCard(task.id) { $0.body = "修好登录页 派子代理" }
        // 开工的第一句由假扩展收下时记进会话文件，带着投送请求 id：会话认得出是 Cue 发的，不算他在场
        try await eventually("开工的第一句发进会话") { !session.messages.isEmpty }
        let file = try #require(rig.app.host.sessionFiles[session.sessionID])
        session.setState(["kind": "thinking"])
        try file.reply("派了 ui 去跑测试")
        session.sendInfo(["subagents": [Self.ui("running", action: "Run $ swift test")]])
        try await eventually("名册写进库") { try await store.sessions(matching: session.sessionID).first?.subagents.isEmpty == false }
        session.setState(["kind": "delegating"])
        // 名册先到（立即写），随后的等子代理只是工作中细节的变化，按写入节流晚到：节流的间隔不真等
        rig.jump(by: PiStateRecorder.detailInterval)
        try await eventually("等子代理写进库、派活那一轮的回答读到") {
            let record = try await store.sessions(matching: session.sessionID).first
            return record?.state == .known(.delegating) && record?.lastReply == "派了 ui 去跑测试"
        }

        try await say("你好", in: workspace, rig)
        try await rig.message(.cue, containing: "收到：你好")
        let keeper = try #require(rig.services.cue.keeper)
        let hello = try #require(keeper.rounds.last { $0.wake == .message })
        #expect(hello.sent.first?.contains("变化（上次醒来之后）：无") == true, "\(hello.sent)")
        #expect(!keeper.rounds.contains { $0.wake.isSessionActivity })

        // 子代理交回（在主会话为它跑完那一轮之前仍在飞）；FireCode 投回结果、指挥官再跑一轮：歇下先写进库，回答随后才落盘
        try await store.recordViewing(device: "phone", sessionIDs: [session.sessionID], cue: false)
        session.sendInfo(["subagents": [Self.ui("done", action: "测试全过")]])
        try file.user("<firecode_master_event>\nui 交回：测试全过\n</firecode_master_event>")
        session.setState(["kind": "thinking"])
        session.setState(["kind": "idle"])
        try await eventually("歇下写进库") { try await store.sessions(matching: session.sessionID).first?.state == .known(.settled) }
        try file.reply("子代理做完：测试全过")
        try await rig.message(.cue, containing: "登录页那边歇下了")
        try await eventually("这一轮做完") { try await store.cueState()?.state == .known(.settled) }
        let woke = keeper.rounds.filter { $0.wake.isSessionActivity }
        #expect(woke.count == 1)
        #expect(woke.first?.sent.first?.contains("（最新的回答）：\n      子代理做完：测试全过") == true, "\(woke.map(\.sent))")
        await rig.stop()
    }

    /// 另一台（在线的）Mac 上的会话在等子代理，在跑的子代理最后一次进展快满 `stallAfter`：到点 Cue 醒来一次，变化写"等子代理 20 分钟没动静"；
    /// 之后你跟 Cue 说话，同一段停滞不再出现在变化里。他自己发起的那一轮里停住的不报：Cue 对它说不进去（他那一轮不插嘴）。
    @Test func 在跑的子代理太久没进展_叫醒一次_他那一轮的不报() async throws {
        let rig = try await CueHostTests.Rig()
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("修好登录页 子代理停住", in: project.id)
        try await store.linkCard(task.id, toSession: "remote-1")
        let his = try await store.createTask("修好注册页 他那一轮", in: project.id)
        try await store.linkCard(his.id, toSession: "remote-his")
        let due = rig.clock.now.addingTimeInterval(60)
        let ui = PiSubagentState(
            name: "ui", role: "工程师", phase: .known(.running), action: "bash · swift test", startedAt: due - 3600,
            progressAt: due - PiSessionState.stallAfter)
        let reviewer = PiSubagentState(name: "reviewer", role: "哨兵", phase: .known(.done), startedAt: due - 3600, settledAt: due - 3000, progressAt: due - 3000)
        // 会话在跑只认宿主在线时报的（`runtimeUntil`）：mac-b 像醒着的 Mac 那样先报在线
        try await store.recordMacPresence(host: "mac-b") { true }
        let remote = PiStateRecorder(store: store, hostID: "mac-b")
        // 他在终端里说的那句开了这一轮（Mac 读会话文件写下，没有投送请求）
        try await store.writePiTranscript(PiTranscript(
            sessionID: "remote-his", messages: [PiChatMessage(sessionID: "remote-his", entryID: "u1", seq: 1, role: .user, text: "做到底", at: due - 3600)],
            recap: PiRecap(lastPrompt: "做到底")))
        try await remote.update(sessionID: "remote-his", state: .delegating, title: "修好注册页", subagents: [ui])
        try await remote.update(sessionID: "remote-1", state: .delegating, title: "修好登录页", subagents: [ui, reviewer])
        try await rig.reconciled()  // 还没停住：排好到点的那一下
        rig.jump(to: due)

        try await rig.message(.cue, containing: "子代理那边停住了")
        let keeper = try #require(rig.services.cue.keeper)
        let woke = keeper.rounds.filter { $0.wake.isSessionActivity }
        #expect(woke.count == 1)
        let stalled = try #require(woke.first)
        #expect(stalled.startedAt >= due)
        #expect(stalled.sent.first?.contains("[等子代理 20 分钟没动静] 修好登录页 子代理停住（\(task.id.shortID)）：ui：bash · swift test") == true, "\(stalled.sent)")
        #expect(stalled.sent.first?.contains("[等子代理 20 分钟没动静] 修好注册页") == false, "\(stalled.sent)")
        try await eventually("这一轮做完") { try await store.cueState()?.state == .known(.settled) }

        try await say("你好", in: Workspace(services: rig.services), rig)
        try await rig.message(.cue, containing: "收到：你好")
        let hello = try #require(keeper.rounds.last { $0.wake == .message })
        #expect(hello.sent.first?.contains("变化（上次醒来之后）：无") == true, "\(hello.sent)")
        #expect(keeper.rounds.filter { $0.wake.isSessionActivity }.count == 1)
        await rig.stop()
    }

    /// 子代理停住叫醒的那一轮出错、隔一会儿重试也错（才告诉你）：之后会话处理交回又回到等子代理，同一段停滞不是新变化，不再叫醒；
    /// 下一件真的事（这里是到点的定时）照常叫醒。
    @Test func 停住那一轮出错重试也错_会话来回写不再叫醒() async throws {
        let rig = try await CueHostTests.Rig()
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("修好登录页 子代理停住 先出两次错", in: project.id)
        try await store.linkCard(task.id, toSession: "remote-2")
        let due = rig.clock.now.addingTimeInterval(60)
        let ui = PiSubagentState(
            name: "ui", role: "工程师", phase: .known(.running), action: "bash · swift test", startedAt: due - 3600,
            progressAt: due - PiSessionState.stallAfter)
        let remote = try await rig.remoteMac()
        try await remote.update(sessionID: "remote-2", state: .delegating, title: "修好登录页", subagents: [ui])
        rig.jump(to: due)
        try await rig.message(.cue, containing: "bad things happened", skippingBackoff: true)
        #expect(rig.model.errors == 2)

        // 会话为别的事动了一下（如处理交回的结果）又回到等子代理：会话记录盖上新序号，停住的时刻不变
        try await remote.update(sessionID: "remote-2", state: .thinking, title: "修好登录页", subagents: [ui])
        try await remote.update(sessionID: "remote-2", state: .delegating, title: "修好登录页", subagents: [ui])
        let line = try await store.noteCueLine("核对发布结果", source: .you, remindAt: rig.clock.now.addingTimeInterval(60))
        try await rig.reconciled()  // 会话来回写过都对过账，定时才到点
        rig.jump(to: try #require(line.remindAt))
        try await rig.message(.cue, containing: "定时到点：\(line.id.uuidString.lowercased()) 核对发布结果")
        let keeper = try #require(rig.services.cue.keeper)
        #expect(keeper.rounds.filter { $0.wake.isSessionActivity }.count == 2)
        #expect(try await rig.count("子代理那边停住了") == 0)
        await rig.stop()
    }

    private func say(_ text: String, in workspace: Workspace, _ rig: CueHostTests.Rig) async throws {
        workspace.cue.draft = ComposerDraft(text: text)
        await workspace.speak(to: .cue, from: Bindable(workspace.cue).draft) { $0.stored }.value
    }

    private static func ui(_ state: String, action: String) -> [String: Any] {
        ["name": "ui", "role": "工程师", "state": state, "action": action, "startedAt": FakeExtension.nowMillis, "settledAt": NSNull(), "model": NSNull()]
    }
}
#endif
