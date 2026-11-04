#if os(macOS)
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 一直记着的规矩变了（本机钉上、别的设备迟到同步来的）：下一轮、在跑的这一轮就照新规矩。
extension CueHostTests {
    /// 你在记忆里把一条改成一直记着：Cue 下一轮就照它（系统提示跟上，不等换新）。
    @Test func 改了一直记着的规矩_下一轮就照新规矩() async throws {
        let rig = try await Rig()
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you).line
        Workspace(services: rig.services).pinCueLine(line.id, true)
        try await eventually("钉上了") { try await rig.store.cueMemory().lines.contains { $0.id == line.id && $0.pinned } }
        try await rig.say("一直记着什么")
        let answer = try await rig.message(.cue, containing: "一直记着：")
        #expect(answer.text.contains("推送前先问我"))
        await rig.stop()
    }

    /// Cue 正在跑一轮时你把一条改成一直记着：这一轮当场收到新规矩，接下来的动作照它，不等下一轮。
    @Test func 一轮在跑时改了规矩_这一轮就照新规矩() async throws {
        let rig = try await Rig()
        let keeper = try #require(rig.services.cue.keeper)
        try await rig.say("请等我放行")
        try await eventually("这一轮停在模型那里") { rig.model.holding }
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you).line
        Workspace(services: rig.services).pinCueLine(line.id, true)
        try await eventually("插给了在跑的大脑") { keeper.turn?.round.sent.contains { $0.contains("一直记着（刚改了") && $0.contains("推送前先问我") } == true }
        rig.model.release()
        let answer = try await rig.message(.cue, containing: "这一轮照新规矩")
        #expect(answer.text.contains("推送前先问我"))
        await rig.stop()
    }

    /// 别的设备上把一条旧记忆钉成一直记着、迟到才同步来（修改时间早于这台 Mac 上更晚记下的那条）：在跑的这一轮照样当场收到。
    @Test func 一轮在跑时别的设备迟到同步来的规矩_这一轮也照它() async throws {
        let rig = try await Rig()
        let keeper = try #require(rig.services.cue.keeper)
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you).line
        try await Task.sleep(for: .milliseconds(5))  // 之后记下的那条修改时间更晚
        try await rig.store.noteCueLine("周报每周五发", source: .you)
        try await rig.say("请等我放行")
        try await eventually("这一轮停在模型那里") { rig.model.holding }
        var row = try #require(try await rig.store.syncRow(recordName: line.id.uuidString.lowercased()))
        row.fields["pinned"] = .int(1)
        row.fields["modifiedAt"] = .int(Int64((line.modifiedAt.timeIntervalSince1970 * 1000).rounded()) + 1)
        #expect(try await rig.store.applyRemote([.save(row, systemFields: Data())]).isEmpty)
        try await eventually("插给了在跑的大脑") { keeper.turn?.round.sent.contains { $0.contains("一直记着（刚改了") && $0.contains("推送前先问我") } == true }
        rig.model.release()
        let answer = try await rig.message(.cue, containing: "这一轮照新规矩")
        #expect(answer.text.contains("推送前先问我"))
        await rig.stop()
    }

    /// 一轮在跑时他问以前的事（Cue 还在派活时他顺口问依赖清单里的 Node）：插进去的那段跟信封一样，带上按他的话在会话回复里查到的（`CueTools.related`）。
    @Test func 一轮在跑时他问以前的事_插进去的那段带上查到的会话回复() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("出依赖升级清单", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-deps")
        // 另一台 Mac 上那个会话早先交回的清单（这台没有它的会话文件，替那台 Mac 写下它读到的）
        try await rig.store.writePiTranscript(PiTranscript(sessionID: "remote-deps", messages: [
            PiChatMessage(sessionID: "remote-deps", entryID: "a1", seq: 1, role: .pi, text: "Node 20 已经结束维护，建议把 CI 与部署的 Node 升到 22。", at: .now),
        ], recap: PiRecap()))
        try await rig.say("请等我放行")
        try await eventually("这一轮停在模型那里") { rig.model.holding }
        let asked = "依赖清单里建议 Node 升到几？"
        try await rig.say(asked)
        let keeper = try #require(rig.services.cue.keeper)
        try await eventually("插给了在跑的大脑") { keeper.turn?.round.sent.contains { $0.contains(asked) } == true }
        let interjected = try #require(keeper.turn?.round.sent.last { $0.contains(asked) })
        #expect(interjected.contains("他问的话在会话回复里查到的") && interjected.contains("升到 22"), "\(interjected)")
        rig.model.release()
        await rig.stop()
    }

    /// 一次交出去几句（Cue 停着时他先贴一段长交代、再问一句以前的事）：那句短问句照样按它自己查会话回复，不和长交代拼在一起才查（拼起来超了短问句的长度就查不到）。
    @Test func 一次交几句_里面的短问句照样带上查到的会话回复() async throws {
        let rig = try await Rig()
        let project = try #require(try await rig.store.projects().first)
        let task = try await rig.store.createTask("出依赖升级清单", in: project.id)
        try await rig.store.linkCard(task.id, toSession: "remote-deps")
        try await rig.store.writePiTranscript(PiTranscript(sessionID: "remote-deps", messages: [
            PiChatMessage(sessionID: "remote-deps", entryID: "a1", seq: 1, role: .pi, text: "Node 20 已经结束维护，建议把 CI 与部署的 Node 升到 22。", at: .now),
        ], recap: PiRecap()))
        // 停用时说的几句攒着，再启用时一起交出去
        _ = try await rig.store.updateCueProfile { $0.enabledAt = nil }
        try await eventually("停用收尾做完") { rig.health == nil }
        let long = "设置页那件照这份反馈改：" + String(repeating: "改了不生效、找不到入口、误操作丢了数据，这三类都要处理，先改最多的那类。", count: 4)
        let asked = "依赖清单里建议 Node 升到几？"
        try await rig.say(long)
        try await rig.say(asked)
        let host = TestApp.hostID
        _ = try await rig.store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        try await eventually("两句一起交出去") { rig.rounds.contains { $0.sent.joined().contains(asked) && $0.sent.joined().contains("先改最多的那类") } }
        let sent = try #require(rig.rounds.first { $0.sent.joined().contains(asked) }).sent.joined()
        #expect(sent.contains("他问的话在会话回复里查到的") && sent.contains("升到 22"), "\(sent)")
        await rig.stop()
    }
}
#endif
