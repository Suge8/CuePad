#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    /// Cue 请你允许推送；你选"以后推送代码都不用问"后 Cue 被唤醒，回答写成 Cue 说的，允许清单记上推送（不进记忆）；
    /// 它再问推送就被拒、叫它直接做。回答你的一轮只响一次：问你的那一轮响的是"等你"（正文是要你定什么），那一轮的回复不再响；
    /// 你选完它回的那一轮照常响它的原话（你说完多半已离开 App）。
    @Test func 等你被回答_Cue被唤醒_以后都不用问记进允许清单() async throws {
        let rig = try await Rig()
        try await rig.say("请问我一个问题")
        let question = try await rig.message(.cue, containing: "要推送吗？")
        #expect(question.choices == ["可以", "以后推送代码都不用问"])
        try await rig.message(.cue, containing: "办好了")
        try await rig.services.answerCueQuestion(question.id, "以后推送代码都不用问")
        try await rig.message(.cue, containing: "知道了：以后推送代码都不用问")
        try await eventually("每一轮响一次") {
            rig.notifier.posted.map(\.body) == ["可以推送登录页的修复吗？\n可以 / 以后推送代码都不用问", "知道了：以后推送代码都不用问"]
        }
        #expect(try await rig.store.cueProfile()?.allows == [CueAllow(.push, project: nil)])
        #expect(try await rig.store.cueMemory().lines.isEmpty)
        await #expect(throws: CueStoreError.alreadyAllowed(nil)) { try await rig.store.addCueMessage(.cue, text: "又要推送吗？", ask: try CueAsking(.push, action: "推送修复")) }
        await rig.stop()
    }

    /// Cue 自己醒来的一轮出错（多是网络偶发）：先不告诉你，基线不前移；隔一会儿再醒一次，成了就照常。
    /// 刚启用那一轮出错，重试后照常看一眼；会话有动静那一轮出错，重试时看到的还是同一处变化，成了照常。
    @Test func 自己醒来出错后隔一会儿重试() async throws {
        let rig = try await Rig(failingOnce: ["醒来：刚启用"], prepare: Rig.handOverWork)
        try await rig.message(.cue, containing: "我看了一眼")
        #expect(rig.model.errors == 1)
        try await rig.settleTask(titled: "修好登录页 先出一次错")  // 假模型据此第一次报错
        try await rig.message(.cue, containing: "登录页那边歇下了")
        #expect(rig.model.errors == 2)
        #expect(try await rig.store.cueMessages().allSatisfy { !$0.text.contains("bad things happened") })
        await rig.stop()
    }

    /// 重试也出错：这时才写一条 Cue 的消息告诉你，只说一次。
    @Test func 自己醒来重试也出错才告诉你() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 先出两次错")
        try await rig.message(.cue, containing: "bad things happened")
        #expect(rig.model.errors == 2)
        #expect(try await rig.store.cueMessages().filter { $0.text.contains("bad things happened") }.count == 1)
        await rig.stop()
    }

    /// 会话交了结果，Cue 自己醒来做完（task done）：Cue 自己按证据确认，顶层任务直接完成，不请你确认，给你写一条结果（不是"等你"）；
    /// 这就是对你说过话了，最后那句回复不再写成灰色的一行（几乎是同一句）。
    @Test func 自己醒来做完_告诉你结果_不再写动态() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 请收一下")  // 假模型据此 done
        let report = try await rig.message(.cue, containing: "做完了")
        #expect(report.choices == nil && report.text.contains("- 登录测试全过"))
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("结果已告诉用户") }
        #expect(try await rig.store.card(try #require(report.taskID))?.status == .done)
        #expect(try await rig.store.cueMessagesWaitingForYou().isEmpty)
        #expect(try await rig.store.cueMessages().filter { $0.author == .known(.note) && $0.createdAt >= report.createdAt }.isEmpty)
        await rig.stop()
    }

    /// 你在别处记下的记忆多到要合并（超过视图预算）：后台另起的大脑把待合并的块写成摘要（假模型合第一块）；Cue 不为它醒，换新的第一轮
    /// （这里每次醒来都到了换新线）也不带待合并的块，回你的话照常。
    @Test func 记忆待合并_后台合并_Cue的轮里没有合并() async throws {
        let rig = try await Rig(usage: CueContext.renewAt + 10_000)
        for index in 0..<(CueMemoryView.budget + 4) { try await rig.store.noteCueLine("偏好 \(index)", source: .you) }
        try await eventually("后台写了摘要") { try await !rig.store.cueMemory().summaries.isEmpty }
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let keeper = try #require(rig.services.cue.keeper)
        #expect(keeper.rounds.map(\.wake) == [.enabled, .message])
        // 待合并的块的写法：块头 #lo-hi 独占一行，下面是原行
        #expect(!keeper.rounds.contains { $0.sent.contains { $0.contains(/\n#\d+-\d+\n#\d+\s/) } })
        await rig.stop()
    }
}
#endif
