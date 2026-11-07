#if os(macOS)
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 重点规矩变了：下一轮就照新规矩；一轮在跑时他的话插进去，带上查到的会话回复。
extension CueHostTests {
    /// 你在记忆里把一条标为重点：Cue 下一轮就照它（系统提示跟上，不等换新）。
    @Test func 改了重点规矩_下一轮就照新规矩() async throws {
        let rig = try await Rig()
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let line = try await rig.store.noteCueLine("推送前先问我", source: .you)
        Workspace(services: rig.services).pinCueLine(line.id, true)
        try await eventually("钉上了") { try await rig.store.cueMemory().lines.contains { $0.id == line.id && $0.pinned } }
        try await rig.say("重点有哪些")
        let answer = try await rig.message(.cue, containing: "重点：")
        #expect(answer.text.contains("推送前先问我"))
        await rig.stop()
    }

    /// 一轮在跑时他问以前的事（Cue 还在派活时他顺口问依赖清单里的 Node）：插进去的那段跟信封一样，带上按他的话在会话回复里查到的（`CueTools.related`）。
    @Test func 一轮在跑时他问以前的事_插进去的那段带上查到的会话回复() async throws {
        let rig = try await Rig()
        try await Self.handedBack(rig, "出依赖升级清单", in: "remote-deps", ["Node 20 已经结束维护，建议把 CI 与部署的 Node 升到 22。"])
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
        try await Self.handedBack(rig, "出依赖升级清单", in: "remote-deps", ["Node 20 已经结束维护，建议把 CI 与部署的 Node 升到 22。"])
        let long = "设置页那件照这份反馈改：" + String(repeating: "改了不生效、找不到入口、误操作丢了数据，这三类都要处理，先改最多的那类。", count: 4)
        let sent = try await Self.handedTogether(rig, [long, "依赖清单里建议 Node 升到几？"])
        #expect(sent.contains("先改最多的那类"), "两句一起交出去")
        #expect(sent.contains("他问的话在会话回复里查到的") && sent.contains("升到 22"), "\(sent)")
        await rig.stop()
    }

    /// 一次交两句短问句、各问一件会话交回过的事：两件都带上（先给每句它查到的第一条，再按先后补满），不让前一句查到的几条占满名额。
    @Test func 一次交两句短问句_两件事都带上查到的会话回复() async throws {
        let rig = try await Rig()
        try await Self.handedBack(rig, "出依赖升级清单", in: "remote-deps", [
            "Node 20 已经结束维护，建议把 CI 与部署的 Node 升到 22。", "依赖清单里 Node 那一项排在第二档之后，Node 升级先不急。",
        ])
        try await Self.handedBack(rig, "查清邮件服务", in: "remote-mail", ["上个月退信 31 封，其中邮箱不存在的 13 封，其余是信箱已满。"])
        let sent = try await Self.handedTogether(rig, ["依赖清单里 Node 建议升到几？", "邮件服务那件里退信有几封是邮箱不存在的？"])
        // 只看查到的那一节（他的原话里也有 Node）：依赖那件、邮件那件各有一条
        let found = sent.components(separatedBy: "他问的话在会话回复里查到的").dropFirst().first?.components(separatedBy: "醒来：").first ?? ""
        #expect(found.contains("Node") && found.contains("邮箱不存在的 13 封"), "\(sent)")
        await rig.stop()
    }

    /// 一条长交代末尾带一句问句：只看最后一句，它是短问句就照样查（他的问话放在最后；贴来的长文里的问句在中间，不查）。
    @Test func 长交代末尾的问句_照样带上查到的会话回复() async throws {
        let rig = try await Rig()
        try await Self.handedBack(rig, "出依赖升级清单", in: "remote-deps", ["Node 20 已经结束维护，建议把 CI 与部署的 Node 升到 22。"])
        let long = "设置页那件照这份反馈改：" + String(repeating: "为什么改了不生效？找不到入口怎么办？误操作丢了数据，这几类都要处理。", count: 3)
        let sent = try await Self.handedTogether(rig, [long + "另外，依赖清单里 Node 建议升到几？"])
        #expect(sent.contains("他问的话在会话回复里查到的") && sent.contains("升到 22"), "\(sent)")
        await rig.stop()
    }

    /// 另一台 Mac 上一个绑着任务的会话早先交回的这几段（这台没有它的会话文件，替那台 Mac 写下它读到的）。
    static func handedBack(_ rig: Rig, _ title: String, in sessionID: String, _ replies: [String]) async throws {
        let project = try #require(try await rig.store.projects().first)
        try await rig.store.linkCard(try await rig.store.createTask(title, in: project.id).id, toSession: sessionID)
        try await rig.store.writePiTranscript(PiTranscript(sessionID: sessionID, messages: replies.enumerated().map { index, text in
            PiChatMessage(sessionID: sessionID, entryID: "a\(index)", seq: Int64(index + 1), role: .pi, text: text, at: .now)
        }, recap: PiRecap()))
    }

    /// 停用时说这几句，再启用时一起交出去：返回交出它们的那一轮发给大脑的。
    static func handedTogether(_ rig: Rig, _ said: [String]) async throws -> String {
        _ = try await rig.store.updateCueProfile { $0.enabledAt = nil }
        try await eventually("停用收尾做完") { rig.health == nil }
        for text in said { try await rig.say(text) }
        let host = TestApp.hostID
        _ = try await rig.store.updateCueProfile { $0.hostID = host; $0.enabledAt = .now }
        let last = try #require(said.last)
        try await eventually("几句一起交出去") { rig.rounds.contains { $0.sent.joined().contains(last) } }
        return try #require(rig.rounds.first { $0.sent.joined().contains(last) }).sent.joined()
    }
}
#endif
