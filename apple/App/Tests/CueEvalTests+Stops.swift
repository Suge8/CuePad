#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

/// 会话停下时归谁、打扰不打扰：要按他口味定的（请他选）、他自己那一轮里的（应一声不管，碰上先问的留给他回）、要他看完再聊的（一句结论再留给他）。
extension CueEvalTests {
    @Test func y审美取舍请他选() async throws {
        try await CueEval.run(
            "y-审美取舍请他选",
            expect: "会话出了主按钮两个配色方案（效果图发到手机），停下问用哪个：不替他挑，tell 带 ask=taste 关联任务，doing 写推荐的方案 1，"
                + "show 两张、推荐的在前；他在卡上点了可以，把方案 1 转给会话"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working("换主按钮配色", "登录页主按钮太灰，换一个更醒目的颜色。做完的标准：改前改后截图发到手机；项目已有的检查通过。")
            try await rig.shots([("color-indigo.png", "方案 1：靛蓝"), ("color-green.png", "方案 2：墨绿")], from: work)
            try await eval.trigger {
                try await rig.ask(
                    work, said: "出了两个配色方案，效果图发到手机了：1 靛蓝，和 Logo 同色；2 墨绿，更沉稳。我倾向 1。",
                    question: "主按钮用哪个配色？", options: ["1 靛蓝", "2 墨绿"])
            }
            let asked = eval.calls("tell").filter { !$0.call.failed && $0.args["ask"] != nil }
            let shown = Self.shown(asked.last?.args["show"], in: try await rig.store.previews(of: work.id))
            let card = try await eval.said().last { $0.choices != nil && $0.taskID == work.task.id }
            var checks = [
                Check(.ask, "没替他挑（没对会话 say）", eval.calls("task", "say").isEmpty),
                Check(.ask, "请他选（tell 带 ask=taste、关联这件任务）", card != nil && asked.contains { $0.args["ask"] as? String == "taste" }),
                Check(.tool, "doing 写推荐的方案 1", (asked.last?.args["doing"] as? String)?.contains(/1|靛蓝/) == true),
                Check(.tool, "show 两个方案、推荐的在前", shown.map(\.name) == ["color-indigo.png", "color-green.png"]),
                Check(.interrupt, "没留给他（leave 没成）、没另 tell", !eval.calls("task", "leave").contains { !$0.call.failed } && !eval.calls("tell").contains { $0.args["ask"] == nil && $0.args["text"] != nil }),
            ]
            guard let card else { return checks }
            try await eval.trigger { try await rig.services.answerCueQuestion(card.id, CueAsk.once) }
            let said = eval.calls("task", "say").filter { !$0.call.failed }.compactMap { $0.args["text"] as? String }
            checks.append(Check(.result, "他点了可以：把方案 1 转给会话", said.contains { $0.contains(/1|靛蓝/) }))
            return checks
        }
    }

    @Test func z只是应一声() async throws {
        try await CueEval.run(
            "z-只是应一声",
            expect: "他 15 分钟前在会话里说限流那条先不做，会话只应了一声（「好，限流不做，同意。」）就歇下、没在等他：不留给他、不 tell、不发等你"
        ) { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger {
                try await eval.rig.settleHisTurn(work, said: "限流那条先不做了，以后再说。", ago: 15 * 60, reply: "好，限流不做，同意。")
            }
            return [
                Check(.ask, "没留给他（没 leave）", eval.calls("task", "leave").isEmpty),
                Check(.ask, "没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
                Check(.interrupt, "没打扰他（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func o他那一轮碰上推送() async throws {
        try await CueEval.run(
            "o2-他那一轮碰上推送",
            expect: "他 15 分钟前在会话里说测试过了就提交，会话提交后停下问要不要推送（他那一轮碰上先问的）：task leave 留给他回，不替他答、不 tell、不发 Cue 的等你"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            try await eval.trigger {
                let his = "测试都过了就提交吧。"
                let messages = [
                    work.prompt, rig.reply(work, "后端和登录页都做好了，测试 23 个、lint 全过。"),
                    PiChatMessage(sessionID: work.id, entryID: "u2", seq: 3, role: .user, text: his, at: .now - 15 * 60),
                    PiChatMessage(sessionID: work.id, entryID: "a2", seq: 4, role: .pi, text: "提交好了（3f9c2ab）。", at: .now),
                ]
                try await rig.store.writePiTranscript(PiTranscript(sessionID: work.id, messages: messages, recap: PiRecap(pendingPrompt: his)))
                let question = "要推送到 origin/main 吗？"
                work.session.sendInfo(["question": ["id": "p1", "kind": "select", "text": question, "options": ["推送", "不推送"]]])
                work.session.setState(["kind": "waiting_user", "title": question])
            }
            let said = eval.calls("task", "say").compactMap { $0.args["text"] as? String }
            return [
                Check(.result, "留给了他（leave 成了）", eval.calls("task", "leave").contains { !$0.call.failed }),
                Check(.ask, "没替他答（没 say 推送）", !said.contains { $0.trimmingCharacters(in: .whitespaces) == "推送" || $0 == "1" }),
                Check(.ask, "没发 Cue 的等你", try await eval.said().allSatisfy { $0.choices == nil }),
                Check(.interrupt, "没打扰他（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func o调研交回要他看() async throws {
        try await CueEval.run(
            "o3-调研交回要他看",
            expect: "调研推送方案交回（正文写着他看完再定）：一句 tell 关联任务说结论与要他定什么，再 task leave 留给他；先不 done、不发等你"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working(
                "比较两种推送方案",
                "比较演示项目发推送用 APNs 直连还是 Firebase Cloud Messaging：成本、维护量、安卓支持，给出推荐与理由。他看完再定用哪个。做完的标准：一份对比与推荐。")
            try await eval.trigger { try await rig.settle(work, reply: Self.pushResearch) }
            let calls = eval.round?.calls ?? []
            let told = eval.calls("tell").filter { !$0.call.failed && $0.args["ask"] == nil && $0.args["text"] != nil }
            let text = told.first?.args["text"] as? String ?? ""
            let tellAt = calls.firstIndex { $0.name == "tell" && !$0.failed }
            let leaveAt = calls.lastIndex { $0.name == "task" && !$0.failed && $0.arguments.contains(#""leave""#) }
            return [
                Check(.interrupt, "一句 tell 说完", told.count == 1),
                Check(.tool, "tell 关联这件任务", told.contains { CueEval.refers($0.args, to: work.id, title: work.task.heading, cards: [work.task]) }),
                Check(.result, "tell 说了结论（推荐 APNs）与要他定的（安卓）", text.contains("APNs") && text.contains(/安卓|Android/)),
                Check(.result, "先 tell 再留给他（leave 成了）", tellAt != nil && leaveAt.map { $0 > tellAt! } == true),
                Check(.result, "先不 done", eval.calls("task", "done").isEmpty),
                Check(.ask, "没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
            ]
        }
    }

    static let pushResearch = """
        对比做完了：

        | | APNs 直连 | Firebase Cloud Messaging |
        |---|---|---|
        | 成本 | 免费 | 免费 |
        | 维护 | 自己管证书与重试，约 200 行 | SDK 包办，多一个 Google 依赖 |
        | 安卓 | 不支持 | 支持 |

        推荐 APNs 直连：现在只有 iOS，少一个第三方依赖、数据不出苹果。
        要你定的：安卓版一年内做不做——要做就直接上 FCM，省得以后迁移。
        """
}
#endif
