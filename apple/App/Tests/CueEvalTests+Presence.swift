#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

extension CueEvalTests {
    @Test func l底下直接回了卡上的事() async throws {
        try await CueEval.run(
            "l-底下直接回了卡上的事",
            expect: "卡上问着按方案 1 改提问卡；他不点卡，在 Cue 页底下说「用 2，按钮再小一点」："
                + "照方案 2 加上按钮再小一点让会话去做；卡随他开口收起，不放回，不再为这件事发等你"
        ) { eval in
            let (work, question) = try await Self.proposalsAsked(eval)
            try await eval.trigger { try await eval.rig.say("用 2，按钮再小一点") }
            let said = eval.calls("task", "say").compactMap { $0.args["text"] as? String }
            let card = try await eval.rig.store.cueMessages().first { $0.id == question.id }
            return [
                Check("让会话照方案 2 做（说到 2 或对话里问）", said.contains { $0.contains(/2|二|对话里问/) }),
                Check("带上按钮再小一点", said.contains { $0.contains(/小/) }),
                Check("卡收起着（没放回）", card?.setAsideBy != nil),
                Check("没再为这件事发等你", !eval.calls("tell").contains { $0.args["ask"] != nil }),
                Check("没收掉这件事（没 done）", eval.calls("task", "done").isEmpty && work.task.status != .done),
            ]
        }
    }

    @Test func m底下说的是别的事() async throws {
        try await CueEval.run(
            "m-底下说的是别的事",
            expect: "卡上问着按方案 1 改提问卡；他在 Cue 页底下问的是另一件事（README 截图那件做到哪了），卡随他开口收起：答他问的，把卡放回等你"
        ) { eval in
            let (_, question) = try await Self.proposalsAsked(eval)
            try await eval.trigger { try await eval.rig.say("README 截图那件做到哪了？") }
            return [
                Check("没撤回", !eval.calls("tell").contains { $0.args["withdraw"] != nil }),
                Check("放回了等你", try await eval.rig.store.cueMessagesWaitingForYou().contains { $0.id == question.id }),
                Check("回了他", try await eval.reply() != nil),
            ]
        }
    }

    @Test func n他走开后的常规问题() async throws {
        try await CueEval.run(
            "n-他走开后的常规问题",
            expect: "他 15 分钟前直接在会话里补了一句（不在场），会话做完那句停下来问一个常规的技术取舍：Cue 接着推进（say 作答），不留给他、不发等你"
        ) { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await eval.rig.settleHisTurn(
                    work, said: "限流顺便也加到登录接口上，同一个 IP 一分钟最多 10 次。", ago: 15 * 60,
                    reply: "登录接口的限流加好了骨架。计数放哪里还没定：A. 进程内存（简单，但多实例不共享）；B. Redis（项目里已经在用，多实例共享）。你选哪个？我倾向 B。")
            }
            return [
                Check("对会话 say 作答（说到 Redis 或 B）", eval.calls("task", "say").contains { ($0.args["text"] as? String)?.contains(/Redis|B/) == true }),
                Check("没留给他（没 leave）", eval.calls("task", "leave").isEmpty),
                Check("没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
            ]
        }
    }

    @Test func o答他自己问的() async throws {
        try await CueEval.run(
            "o-答他自己问的",
            expect: "他 15 分钟前在会话里自己问了个问题（不在场），会话答完停下：Cue 不替他接（不 say），task leave 留给他，会话显示待回复"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await rig.settleHisTurn(
                    work, said: "等下，重置令牌为什么要存哈希而不是原文？", ago: 15 * 60,
                    reply: "存哈希是为了库被拖走时令牌不能直接拿来用：令牌本身就等于一次性密码，原文落库的话，谁读到库谁就能重置任何人的密码。验证时把用户带来的令牌同样哈希再比对就行，代价只是一次 SHA-256。")
            }
            let session = try #require(try await rig.store.sessions(matching: work.id).first)
            let duty = try await rig.store.cueDuty()
            return [
                Check("没对会话说话（没 say）", eval.calls("task", "say").isEmpty),
                Check("留给了他（leave 成了）", eval.calls("task", "leave").contains { !$0.call.failed }),
                Check("会话行显示待回复", PiShown(session, cue: duty, at: .always()).label == "待回复"),
                Check("没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
                Check("留给他了就不补「不打算行动」", try await eval.said().allSatisfy { !$0.text.contains("不打算行动") }),
            ]
        }
    }

    @Test func t他刚说过话_Cue说的那一轮做完照样收尾() async throws {
        try await CueEval.run(
            "t-Cue说的那一轮做完照样收尾",
            expect: "他 7 分钟前在会话里说过话，之后 Cue 说的那句开的一轮做完（带测试输出与截图）：归 Cue，被叫醒、核对后 done"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            try await rig.shots([("登录页改前改后.png", "登录页 忘记密码 改前改后")], from: work, drawing: { _ in try loginShot() })
            try await eval.trigger {
                try await rig.settleCueTurn(
                    work, his: "进度怎么样了？", ago: 7 * 60, cue: "把测试输出和改前改后的截图补上。", reply: Self.doneReply)
            }
            return [
                Check("被叫醒（这一停没标他说的）", eval.round?.sent.contains { $0.contains("[歇下] \(Self.title)") } == true),
                Check("done 了", eval.calls("task", "done").contains { !$0.call.failed }),
            ]
        }
    }

    @Test func q他离开后接着推进() async throws {
        try await CueEval.run(
            "q-他离开后接着推进",
            expect: "他在会话里发起的一轮停下问常规取舍时他正在手机上开着它（归他，不叫醒 Cue）；他离开那一页后 Cue 被叫醒，接着推进（say 作答）"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            try await rig.store.recordViewing(device: "phone", sessionID: work.id, cue: false)
            let viewing = Date.now
            try await rig.settleHisTurn(
                work, said: "限流顺便也加到登录接口上，同一个 IP 一分钟最多 10 次。", ago: 15 * 60,
                reply: "登录接口的限流加好了骨架。计数放哪里还没定：A. 进程内存（简单，但多实例不共享）；B. Redis（项目里已经在用，多实例共享）。你选哪个？我倾向 B。")
            try await eventually("这一停写进库") {
                try await rig.store.sessions(matching: work.id).first.map { $0.state == .known(.settled) && $0.answered } == true
            }
            try await eval.trigger { try await rig.store.recordViewing(device: "phone", sessionID: nil, cue: false) }
            return [
                Check("他开着时没叫醒 Cue（之后只有他离开后那一轮）", rig.rounds.filter { $0.startedAt >= viewing }.count == 1),
                Check("他离开后被叫醒（信封里这一停标着他说的）", eval.round?.sent.contains { $0.contains("他说的") } == true),
                Check("接着推进（say 说到 Redis 或 B）", eval.calls("task", "say").contains { ($0.args["text"] as? String)?.contains(/Redis|B/) == true }),
            ]
        }
    }
}
#endif
