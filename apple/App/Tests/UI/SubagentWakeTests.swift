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
        var file = try SessionLog(rig.app.piPaths.sessionsDirectory.appending(path: "--demo--/\(session.sessionID).jsonl"), id: session.sessionID)

        try await eventually("开工的第一句发进会话") { !session.messages.isEmpty }
        let opening = try #require(session.messages.first)
        try file.append(user: opening.text, delivery: opening.deliveryID)  // 带着投送请求 id：会话认得出是 Cue 发的，不算他在场
        session.setState(["kind": "thinking"])
        try file.append(reply: "派了 ui 去跑测试")
        session.sendInfo(["subagents": [Self.ui("running", action: "Run $ swift test")]])
        session.setState(["kind": "delegating"])
        // 名册先到（立即写），随后的等子代理只是工作中细节的变化，按写入节流晚到
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
        try await store.recordViewing(device: "phone", sessionID: session.sessionID, cue: false)
        session.sendInfo(["subagents": [Self.ui("done", action: "测试全过")]])
        try file.append(user: "<firecode_master_event>\nui 交回：测试全过\n</firecode_master_event>")
        session.setState(["kind": "thinking"])
        session.setState(["kind": "idle"])
        try await eventually("歇下写进库") { try await store.sessions(matching: session.sessionID).first?.state == .known(.settled) }
        try file.append(reply: "子代理做完：测试全过")
        try await rig.message(.cue, containing: "登录页那边歇下了")
        try await eventually("这一轮做完") { try await store.cueState()?.state == .known(.settled) }
        let woke = keeper.rounds.filter { $0.wake.isSessionActivity }
        #expect(woke.count == 1)
        #expect(woke.first?.sent.first?.contains("回复：子代理做完：测试全过") == true, "\(woke.map(\.sent))")
        await rig.stop()
    }

    /// 另一台 Mac 上的会话在等子代理，在跑的子代理最后一次进展快满 `stallAfter`：到点 Cue 醒来一次，变化写"等子代理 20 分钟没动静"；
    /// 之后你跟 Cue 说话，同一段停滞不再出现在变化里。
    @Test func 在跑的子代理太久没进展_叫醒一次() async throws {
        let rig = try await CueHostTests.Rig()
        let store = rig.store
        let project = try #require(try await store.projects().first)
        let task = try await store.createTask("修好登录页 子代理停住", in: project.id)
        try await store.linkCard(task.id, toSession: "remote-1")
        let due = Date.now.addingTimeInterval(3)
        let ui = PiSubagentState(
            name: "ui", role: "工程师", phase: .known(.running), action: "bash · swift test", startedAt: due - 3600,
            progressAt: due - PiSessionState.stallAfter)
        let reviewer = PiSubagentState(name: "reviewer", role: "哨兵", phase: .known(.done), startedAt: due - 3600, settledAt: due - 3000, progressAt: due - 3000)
        try await PiStateRecorder(store: store, hostID: "mac-b")
            .update(sessionID: "remote-1", state: .delegating, title: "修好登录页", subagents: [ui, reviewer])

        try await rig.message(.cue, containing: "子代理那边停住了")
        let keeper = try #require(rig.services.cue.keeper)
        let woke = keeper.rounds.filter { $0.wake.isSessionActivity }
        #expect(woke.count == 1)
        let stalled = try #require(woke.first)
        #expect(stalled.startedAt >= due)
        #expect(stalled.sent.first?.contains("[等子代理 20 分钟没动静] 修好登录页 子代理停住（\(task.id.shortID)）：ui：bash · swift test") == true, "\(stalled.sent)")
        try await eventually("这一轮做完") { try await store.cueState()?.state == .known(.settled) }

        try await say("你好", in: Workspace(services: rig.services), rig)
        try await rig.message(.cue, containing: "收到：你好")
        let hello = try #require(keeper.rounds.last { $0.wake == .message })
        #expect(hello.sent.first?.contains("变化（上次醒来之后）：无") == true, "\(hello.sent)")
        #expect(keeper.rounds.filter { $0.wake.isSessionActivity }.count == 1)
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

/// 像 Pi 那样逐条追加的会话文件（v3：每条接在上一条后面）：时间戳是写下的此刻。
private struct SessionLog {
    let url: URL
    private var last: String?

    init(_ url: URL, id: String) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: url)
        try write(["type": "session", "version": 3, "id": id, "timestamp": Self.stamp(), "cwd": url.deletingLastPathComponent().path])
    }

    /// `delivery` 是 CuePad 投进来的那句的请求 id（Pi 写成 `cuepadDelivery`）。
    mutating func append(user text: String, delivery: String? = nil) throws {
        try message(["role": "user", "content": text, "cuepadDelivery": delivery ?? NSNull()])
    }

    mutating func append(reply text: String) throws {
        try message(["role": "assistant", "stopReason": "stop", "content": [["type": "text", "text": text]]])
    }

    private mutating func message(_ body: [String: Any]) throws {
        let id = UUID().uuidString
        var message = body
        message["timestamp"] = Int(Date.now.timeIntervalSince1970 * 1000)
        try write(["type": "message", "id": id, "parentId": last ?? NSNull(), "timestamp": Self.stamp(), "message": message])
        last = id
    }

    private func write(_ entry: [String: Any]) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: try JSONSerialization.data(withJSONObject: entry) + Data("\n".utf8))
    }

    private static func stamp() -> String {
        let format = ISO8601DateFormatter()
        format.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return format.string(from: .now)
    }
}
#endif
