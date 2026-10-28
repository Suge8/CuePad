#if os(macOS)
import CuePi
import CueStore
import CueTestSupport
import CueText
import Foundation
import Testing
@testable import CuePad

extension CueEvalTests {
    @Test func f会话出错() async throws {
        try await CueEval.run("f1-会话出错", expect: "会话报 API 500：say 让它继续（重试一次）或换模型，不打扰用户") { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            try await eval.trigger { work.session.setState(["kind": "error", "error": #"500 {"type":"error","error":{"type":"api_error","message":"Internal server error"}}"#]) }
            return [
                Check(.result, "对会话 say（继续或换模型）", !eval.calls("task", "say").isEmpty),
                Check(.interrupt, "没打扰用户（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func f额度用完() async throws {
        try await CueEval.run("f2-额度用完", expect: "会话报额度用完：告诉用户") { eval in
            let work = try await eval.rig.working(Self.title, Self.body)
            let quota = #"400 {"type":"error","error":{"type":"invalid_request_error","message":"You have reached your specified API usage limits. You will regain access on 2026-11-01 at 00:00 UTC."}}"#
            try await eval.trigger { work.session.setState(["kind": "error", "error": quota]) }
            let told = try await eval.said().contains { $0.author == .known(.cue) }
            return [Check(.interrupt, "tell 告诉用户", !eval.calls("tell").isEmpty && told)]
        }
    }

    @Test func s等子代理停住() async throws {
        try await CueEval.run(
            "s-等子代理停住",
            expect: "会话派了子代理 e2e 跑端到端测试、自己在等，e2e 20 分钟没动静：Cue 对那个会话 say，点名 e2e 多久没动静、让它自己判断（卡住就停掉重派或接手，在正常跑就接着等）；不 tell 他、不停会话"
        ) { eval in
            let rig = eval.rig
            let project = try #require(try await rig.store.projects().first { $0.name == "演示" })
            let first = "\(Self.title)\n\(Self.body)", id = "s-\(UUID().uuidString.prefix(8).lowercased())", delivery = UUID()
            let task = try await rig.store.createTask(first, in: project.id)
            try await rig.store.linkCard(task.id, toSession: id)
            try await rig.store.recordSend(first, to: SendTarget(kind: .piSession, name: Self.title, ref: id), card: task.id, delivery: delivery, origin: .known(.cue))
            let dispatched = "后端与登录页都改好了，单元测试 23 个全过。派了 e2e 去跑端到端测试（真浏览器走一遍忘记密码），等它交回再汇报。"
            try await eval.trigger {
                // 在另一台 Mac 上：e2e 最后一次进展再过 3 秒满 20 分钟
                let due = Date.now.addingTimeInterval(3)
                let e2e = PiSubagentState(
                    name: "e2e", role: "工程师", phase: .known(.running), action: "bash · npx playwright test reset-password", startedAt: due - 1800,
                    progressAt: due - PiSessionState.stallAfter)
                try await PiStateRecorder(store: rig.store, hostID: "mac-b")
                    .update(sessionID: id, state: .delegating, title: Self.title, turnStartedAt: due - 1900, subagents: [e2e])
                let prompt = PiChatMessage(sessionID: id, entryID: "u1", seq: 1, role: .user, text: first, at: due - 3600, deliveryID: delivery)
                let reply = PiChatMessage(sessionID: id, entryID: "a1", seq: 2, role: .pi, text: dispatched, at: due - 1800)
                try await rig.store.writePiTranscript(PiTranscript(
                    sessionID: id, messages: [prompt, reply], recap: PiRecap(lastPrompt: oneLine(first), lastReply: dispatched, answeredAt: due - 1800)))
            }
            let toIt = eval.calls("task", "say").filter { !$0.call.failed && CueEval.refers($0.args, to: id, title: Self.title, cards: [task]) }
            let said = toIt.compactMap { $0.args["text"] as? String }
            return [
                Check(.result, "对这件任务的会话 say", !toIt.isEmpty),
                Check(.result, "say 点名 e2e 与多久没动静", said.contains { $0.contains("e2e") && $0.contains(/20|二十/) }),
                Check(.interrupt, "没打扰他（没 tell）", eval.calls("tell").isEmpty),
                Check(.result, "没停会话（没 stop、没 done）", eval.calls("task", "stop").isEmpty && eval.calls("task", "done").isEmpty),
            ]
        }
    }

    @Test func g答问() async throws {
        try await CueEval.run("g-答问", expect: "用户问在做的那件做到哪了：直接回答进展，不派新活") { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            let next = "后端好了，接着做前端：登录页的入口、填邮箱的页面和提示文案。"
            let delivery = UUID()
            try await rig.store.recordSend(next, to: SendTarget(kind: .piSession, name: Self.title, ref: work.id), card: work.task.id, delivery: delivery, origin: .known(.cue))
            let backend = "后端做完了：POST /api/password/reset-request 发重置邮件（沿用注册验证邮件模板），令牌 30 分钟过期、用过即失效，同一邮箱 60 秒限一次。新增 14 个测试全过。"
            try await rig.store.writePiTranscript(PiTranscript(
                sessionID: work.id,
                messages: [work.prompt, rig.reply(work, backend), PiChatMessage(sessionID: work.id, entryID: "u2", seq: 3, role: .user, text: next, at: .now, deliveryID: delivery)],
                recap: PiRecap(lastPrompt: oneLine(work.prompt.text), lastReply: backend, pendingPrompt: next)))
            work.session.setState(["kind": "tool", "tool": "bash", "detail": "npm test -- reset-password"])
            try await eventually("在跑测试写进库") { try await rig.store.sessions(matching: work.id).first?.state == .known(.tool) }
            try await eval.trigger { try await rig.say("登录页那件做到哪了？") }
            let reply = try await eval.reply()
            return [
                Check(.result, "没派新活（没 add、start）", eval.calls("task", "add").isEmpty && eval.calls("task", "start").isEmpty),
                Check(.result, "回答了进展（提到后端、前端或测试）", reply?.text.contains(/后端|前端|测试|接口|表单/) == true),
                Check(.interrupt, "他发起的一轮不另 tell", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func h做完的事的会话答完() async throws {
        try await CueEval.run("h-做完的事的会话答完", expect: "已完成的事的会话被 Cue 的一句恢复、答完歇下：再 done 那件事结束会话，不另开活、不打扰用户") { eval in
            let rig = eval.rig
            let work = try await rig.working(Self.title, Self.body)
            try await rig.store.setStatus(work.task.id, .done)  // 早已做完，会话是被下面这句恢复的
            let asked = "复查一遍：限流有没有绕过的办法？", delivery = UUID()
            try await rig.store.recordSend(asked, to: SendTarget(kind: .piSession, name: Self.title, ref: work.id), card: work.task.id, delivery: delivery, origin: .known(.cue))
            let question = PiChatMessage(sessionID: work.id, entryID: "u2", seq: 3, role: .user, text: asked, at: .now, deliveryID: delivery)
            let answer = PiChatMessage(sessionID: work.id, entryID: "a2", seq: 4, role: .pi, text: "复查过了：限流按邮箱哈希计数、存在服务端，换 IP 或改大小写都绕不过去。", at: .now)
            try await eval.trigger {
                work.session.setState(["kind": "idle"])
                try await rig.answered(
                    work.id, prompt: asked, reply: answer.text, messages: [work.prompt, rig.reply(work, Self.doneReply), question, answer])
            }
            let ended = try await rig.store.deliveryRequests(toSession: work.id).contains { $0.mode == .known(.end) }
            return [
                Check(.result, "再 done 了这件事", eval.calls("task", "done").contains { !$0.call.failed }),
                Check(.result, "请会话结束", ended),
                Check(.result, "没另开活（没 add、start）", eval.calls("task", "add").isEmpty && eval.calls("task", "start").isEmpty),
                Check(.ask, "没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
                Check(.interrupt, "没打扰他（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    @Test func k挑图提问() async throws {
        try await CueEval.run(
            "k-挑图提问",
            expect: "会话交回三个提问卡视觉方案（每个方案手机浅色、深色、原样与 Mac 四张，还夹着先前别的改动的截图），长相只能按他口味定："
                + "tell 带 ask=taste 关联任务，doing 写推荐的那个，show 每个方案一张、同一种样子、推荐的在前，每张一句看什么；不带别的改动的图，不 leave"
        ) { eval in
            let rig = eval.rig
            let work = try await Self.proposalsDelivered(eval)
            let previews = try await rig.store.previews(of: work.id)
            let asked = eval.calls("tell").filter { $0.args["ask"] as? String == "taste" && !$0.call.failed }
            let shown = Self.shown(asked.last?.args["show"], in: previews)
            let variants = Set(shown.map { name in Self.proposals.map(\.slug).reduce(name.name) { $0.replacingOccurrences(of: $1, with: "") } })
            return [
                Check(.ask, "请他选（tell 带 ask=taste、关联这件任务）", try await eval.said().contains { $0.choices != nil && $0.taskID == work.task.id } && !asked.isEmpty),
                Check(.ask, "没留给他（leave 没成，问着就不待回复）", !eval.calls("task", "leave").contains { !$0.call.failed }),
                Check(.tool, "doing 写推荐的方案", (asked.last?.args["doing"] as? String)?.contains(/方案|决定单|对话里问|郑重放行/) == true),
                Check(.tool, "show 每个方案一张（3 张、各是一个方案）", shown.count == 3 && Set(shown.map(\.title)).count == 3 && shown.allSatisfy { $0.title.hasPrefix("提问卡方案") }),
                Check(.tool, "同一种样子（同一台设备、同一种外观）", !shown.isEmpty && variants.count == 1),
                Check(.tool, "每张一句看什么", (asked.last?.args["show"] as? [[String: Any]])?.allSatisfy { ($0["look"] as? String)?.isEmpty == false } == true),
                Check(.tool, "没带别的改动的图", !shown.contains { $0.title.hasPrefix("上一轮的改动") }),
            ]
        }
    }

    @Test func u做完只挂最终成果() async throws {
        try await CueEval.run(
            "u-做完只挂最终成果",
            expect: "会话做完侧栏改版，一路发过方案稿、中途两版与最终版（共 5 份），回复带证据："
                + "done 的 show 挂最终版，每张一句看什么；方案稿、中途稿不挂"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working(
                "收口 Mac 侧栏", "Mac 侧栏收口：去掉 Agent 区，会话数并进项目行。做完的标准：项目已有的检查通过；最终版截图发到手机。")
            for batch in [
                [("plan-a-mac.png", "方案稿 A：会话单列一区"), ("plan-b-mac.png", "方案稿 B：会话数并进项目行")],
                [("wip-1-mac.png", "中途一版：分组标题太挤"), ("wip-2-mac-dark.png", "中途二版：深色下状态标错位")],
                [("final-mac.png", "最终版：项目行带会话数")],
            ] {
                try await rig.shots(batch, from: work)
            }
            try await eval.trigger { try await rig.settle(work, reply: Self.sidebarReply) }
            let previews = try await rig.store.previews(of: work.id)
            let done = eval.calls("task", "done").last { !$0.call.failed }
            let picked = done?.args["show"] as? [[String: Any]] ?? []
            let shown = Self.shown(picked, in: previews)
            let report = try await eval.said().last { $0.taskID == work.task.id && $0.choices == nil }
            return [
                Check(.result, "done 了", done != nil),
                Check(.tool, "挂了最终版", shown.contains { $0.name == "final-mac.png" }),
                Check(.tool, "只挂最终版（方案稿、中途稿不挂）", !shown.isEmpty && shown.allSatisfy { $0.title.hasPrefix("最终版") }),
                Check(.tool, "每张一句看什么", !picked.isEmpty && picked.allSatisfy { ($0["look"] as? String)?.isEmpty == false }),
                Check(.tool, "结果上就是点名的这几张", report?.shots.map(\.preview) == shown.map(\.id)),
            ]
        }
    }

    /// show 点名的图（file 写编号前缀）是会话发来的哪几张；认不出的略过
    static func shown(_ show: Any?, in previews: [PiPreview]) -> [PiPreview] {
        (show as? [[String: Any]] ?? []).compactMap { item in
            guard let key = (item["file"] as? String)?.lowercased(), !key.isEmpty else { return nil }
            return previews.first { $0.id.uuidString.lowercased().hasPrefix(key) }
        }
    }
}
#endif
