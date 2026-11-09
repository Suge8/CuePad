#if os(macOS)
import CueAgent
import CuePi
@testable import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    /// （不用先问的例外只在记忆里）。回答你的一轮只响一次：问你的那一轮响的是"等你"（正文是要你定什么），那一轮的回复不再响；
    /// 你选完它回的那一轮照常响它的原话（你说完多半已离开 App）。
    @Test func 等你被回答_Cue被唤醒_以后都不用问记成重点记忆() async throws {
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
        let lines = try await rig.store.cueMemory().lines
        #expect(lines.map(\.text) == ["以后推送代码都不用问"] && lines.allSatisfy { $0.pinned && $0.source == .known(.you) })
        await rig.stop()
    }

    /// 醒来出错多是网络偶发：先不告诉你、基线不前移，隔一会儿再醒。
    @Test func 自己醒来出错后隔一会儿重试() async throws {
        let rig = try await Rig(failingOnce: ["醒来：刚启用"], prepare: Rig.handOverWork)
        try await rig.message(.cue, containing: "我看了一眼", skippingBackoff: true)
        #expect(rig.model.errors == 1)
        try await rig.settleTask(titled: "修好登录页 先出一次错")  // 假模型据此第一次报错
        try await rig.message(.cue, containing: "登录页那边歇下了", skippingBackoff: true)
        #expect(rig.model.errors == 2)
        #expect(try await rig.store.cueMessages().allSatisfy { !$0.text.contains("bad things happened") })
        await rig.stop()
    }

    @Test func 自己醒来重试也出错才告诉你() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 先出两次错")
        try await rig.message(.cue, containing: "bad things happened", skippingBackoff: true)
        #expect(rig.model.errors == 2)
        #expect(try await rig.store.cueMessages().filter { $0.text.contains("bad things happened") }.count == 1)
        await rig.stop()
    }

    @Test func 自己醒来做完_告诉你结果() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页 请收一下")  // 假模型据此 done
        let report = try await rig.message(.cue, containing: "做完了")
        #expect(report.choices == nil && report.text.contains("- 登录测试全过"))
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) && rig.model.answered("结果已告诉用户") }
        #expect(try await rig.store.card(try #require(report.taskID))?.status == .done)
        #expect(try await rig.store.cueMessagesWaitingForYou().isEmpty)
        await rig.stop()
    }

    @Test func 你点完成整件任务_Cue不醒() async throws {
        let rig = try await Rig()
        try await rig.settleTask(titled: "修好登录页")
        try await rig.message(.cue, containing: "登录页那边歇下了")
        try await eventually("这一轮做完") { try await rig.store.cueState()?.state == .known(.settled) }
        let task = try #require(try await rig.store.cueBoard().tasks.first?.task)
        try await Workspace(services: rig.services).complete(task.id)
        #expect(try await rig.store.card(task.id)?.status == .done)
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let keeper = try #require(rig.services.cue.keeper)
        let hello = try #require(keeper.rounds.last { $0.wake == .message })
        #expect(hello.sent.joined().contains("变化（上次醒来之后）：无"), "\(hello.sent)")
        #expect(!keeper.rounds.contains { $0.sent.joined().contains("[完成]") })
        await rig.stop()
    }

    @Test func 记忆待合并_后台合并_Cue的轮里没有合并() async throws {
        let rig = try await Rig(usage: CueContext.renewAt + 10_000)
        for index in 0..<(CueMemoryView.budget + 4) { try await rig.store.noteCueLine("偏好 \(index)", source: .you) }
        try await eventually("后台写了摘要") { try await !rig.store.cueMemory().summaries.isEmpty }
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let keeper = try #require(rig.services.cue.keeper)
        #expect(keeper.rounds.map(\.wake) == [.message])  // 空库启用不醒，记忆待合并也不叫醒 Cue
        #expect(!keeper.rounds.contains { $0.sent.contains { $0.contains("<merge>") } })
        await rig.stop()
    }
}
#endif