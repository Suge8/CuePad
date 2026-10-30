#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

extension CueHostTests {
    /// Cue 请你允许推送；你选"以后推送代码都不用问"后 Cue 被唤醒，回答写成 Cue 说的，记忆里多一条你说的、一直记着的原话
    /// （不用先问的例外只在记忆里）。回答你的一轮只响一次：问你的那一轮响的是"等你"（正文是要你定什么），那一轮的回复不再响；
    /// 你选完它回的那一轮照常响它的原话（你说完多半已离开 App）。
    @Test func 等你被回答_Cue被唤醒_以后都不用问记成一直记着的记忆() async throws {
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
    /// 这就是对你说过话了。
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

    /// 你在别处记下的记忆多到要合并（超过视图预算）：后台另起的大脑把待合并的块写成摘要（假模型合第一块）；Cue 不为它醒，换新的第一轮
    /// （这里每次醒来都到了换新线）也不带待合并的块，回你的话照常。
    @Test func 记忆待合并_后台合并_Cue的轮里没有合并() async throws {
        let rig = try await Rig(usage: CueContext.renewAt + 10_000)
        for index in 0..<(CueMemoryView.budget + 4) { try await rig.store.noteCueLine("偏好 \(index)", source: .you) }
        try await eventually("后台写了摘要") { try await !rig.store.cueMemory().summaries.isEmpty }
        try await rig.say("你好")
        try await rig.message(.cue, containing: "收到：你好")
        let keeper = try #require(rig.services.cue.keeper)
        #expect(keeper.rounds.map(\.wake) == [.message])  // 空库启用不醒，记忆待合并也不叫醒 Cue
        // 待合并的块的写法：块头 #lo-hi 独占一行，下面是原行
        #expect(!keeper.rounds.contains { $0.sent.contains { $0.contains(/\n#\d+-\d+\n#\d+\s/) } })
        await rig.stop()
    }

    /// 一直记着的过了软线（上次整理之后只新钉了几条，不够"新钉多了"那条线）：后台另起的大脑拿到钉着的全部行整理
    /// （假模型看了觉得都不用动），跑完记下交给它的那组；之后记忆再变、那组没变就不再交给它（合待合并的块时也不带）；
    /// 再钉一条，那组变了、仍过软线，再整理一次。
    @Test func 一直记着的过了软线_后台整理_那组不变不再整理() async throws {
        let tidiedFile = { (rig: Rig) in rig.app.directory.appending(path: "Library/Cue/tidied.json") }
        // 一条至多 280 字节：十五条合起来刚过软线（`CueMemoryLine.pinnedSoft`）；前十一条算上次整理过的
        let long = String(repeating: "测", count: 89)
        let rig = try await Rig(prepare: { rig in
            var ids: [UUID] = []
            for index in 0..<15 { ids.append(try await rig.store.noteCueLine("规矩 \(index) \(long)", source: .you, pinned: true).line.id) }
            let file = tidiedFile(rig)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(ids.prefix(11))).write(to: file)
        })
        func tidied() -> Set<UUID> { (try? JSONDecoder().decode(Set<UUID>.self, from: Data(contentsOf: tidiedFile(rig)))) ?? [] }
        func pinned() async throws -> Set<UUID> { Set(try await rig.store.cueMemory().lines.filter(\.pinned).map(\.id)) }
        try await eventually("整理过一次、记下那组") {
            let set = try await pinned()
            return rig.model.tidyAsks == 1 && tidied() == set
        }

        for index in 0..<(CueMemoryView.budget + 4) { try await rig.store.noteCueLine("偏好 \(index)", source: .you) }
        try await eventually("后台合了待合并的块") { try await !rig.store.cueMemory().summaries.isEmpty }
        #expect(rig.model.tidyAsks == 1)

        try await rig.store.noteCueLine("规矩 15 \(long)", source: .you, pinned: true)
        try await eventually("那组变了，再整理一次") {
            let set = try await pinned()
            return rig.model.tidyAsks == 2 && tidied() == set && set.count == 16
        }
        await rig.stop()
    }
}
#endif