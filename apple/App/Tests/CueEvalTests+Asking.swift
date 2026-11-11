#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// 他亲口放行过的那一类（照原话记下、之后不问）、到点的提醒（该打扰、该 urgent），与定时的建与到点开工。会话问问题时该不该问他在 `会话在问` 那张表里。
extension CueEvalTests {
    /// 测"不该问却问"：他亲口说过推送不用问，会话做完问推不推，Cue 直接答（靠当时照原话 note 并 pin 记下）。
    @Test func w放行过的不再问() async throws {
        try await CueEval.run(
            "w-放行过的不再问",
            expect: "他说过「以后推送代码都不用问我，测试过了就推」；会话做完、测试与 lint 都过，问要不要推送：直接答推送，不发等你、不 tell"
        ) { eval in
            let rig = eval.rig
            try await eval.trigger { try await rig.say("以后推送代码都不用问我，测试过了就推。") }
            let allowed = eval.calls("memory", "note").contains { !$0.call.failed && $0.args["pin"] as? Bool == true && ($0.args["text"] as? String)?.contains("推送") == true }
            let work = try await rig.working(Self.title, "登录页加「忘记密码」入口。做完的标准：跑过项目已有的测试与 lint 并贴出输出。推送前先停下来问。")
            try await eval.trigger {
                try await rig.ask(work, said: Self.pushReady, question: "要推送到 origin/main 吗？", options: ["推送", "不推送"])
            }
            return [
                Check(.tool, "他放行时照原话记下并标为重点（memory note pin）", allowed),
                eval.notesArePlain(),
                Check(.ask, "照放行直接答推送", work.answers == ["推送"]),
                Check(.ask, "没发等你", try await eval.said().allSatisfy { $0.choices == nil }),
                Check(.interrupt, "没打扰他（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    /// 测必要的打扰：约好的时间点到了（一次性、没挂任务的定时），tell 带 urgent，只说这一件事。
    @Test func x到点提醒() async throws {
        try await CueEval.run(
            "x-到点提醒",
            expect: "它先前答应他到点提醒给小林回电话（面试改到明早 10 点）；提醒到点：tell 带 urgent 提醒他，一条说完，不派活"
        ) { eval in
            try await eval.trigger {
                _ = try await eval.rig.store.noteCueLine(
                    "提醒他给小林回电话：面试改到明早 10 点，要他确认", source: .cue, remindAt: .now.addingTimeInterval(15))
            }
            let told = eval.calls("tell").filter { !$0.call.failed && $0.args["ask"] == nil && $0.args["text"] != nil }
            return [
                Check(.result, "提醒的是这件事（小林、回电话）", told.contains { ($0.args["text"] as? String)?.contains(/小林|回电话/) == true }),
                Check(.interrupt, "带 urgent", told.contains { $0.args["urgent"] as? Bool == true }),
                Check(.interrupt, "一条说完", told.count == 1),
                Check(.result, "没派活（没 add、start）", eval.calls("task", "add").isEmpty && eval.calls("task", "start").isEmpty),
            ]
        }
    }

    /// 他一句话要定期做一件事：定成每周一 9:00 的定时、挂在一件任务上（任务先建好、不开工）。
    @Test func x2说一句建定时() async throws {
        try await CueEval.run(
            "x2-说一句建定时",
            expect: "他要每周一早上 9 点清理一次过期分支和旧截图：建这件任务（不开工），memory remind 定成每周一 9:00 的定时、挂在它上面，回复一两句"
        ) { eval in
            try await eval.trigger { try await eval.rig.say("每周一早上 9 点清理一次演示项目的过期分支和旧截图") }
            let schedule = try await eval.rig.store.cueSchedules().first?.line
            let reply = try await eval.reply()
            return [
                Check(.tool, "定成每周一 9:00", schedule?.repeats == CueRepeat(.weekly([2]), hour: 9, minute: 0)),
                Check(.result, "挂在任务上", schedule?.task != nil),
                Check(.ask, "没开工（没 start、没开会话）", eval.calls("task", "start").isEmpty
                    && !eval.rig.app.host.calls.contains { if case .open = $0 { true } else { false } }),
                Check(.interrupt, "回复一两句", reply.map { sentences($0.text) <= 2 } == true),
            ]
        }
    }

    /// 挂在任务上的每周定时到点：开工那件任务，这一次的结果是一条会话；任务不 done（done 了就不再定时），不打扰他。
    @Test func x3定时到点开工() async throws {
        try await CueEval.run(
            "x3-定时到点开工",
            expect: "挂在「清理过期分支」上的每周定时到点：start 开工它，不 done 任务，定时还在、排到下一次，不 tell 打扰他"
        ) { eval in
            let store = eval.rig.store
            let project = try #require(try await store.projects().first { $0.name == "演示" })
            let task = try await store.createTask("清理过期分支\n删掉合并超过两周的远端分支，旧截图移到废纸篓。做完的标准：列出删了哪些分支、移走几张图。", in: project.id)
            try await eval.trigger {
                _ = try await store.noteCueLine(
                    "清理过期分支和旧截图", source: .cue, remindAt: .now.addingTimeInterval(15), repeats: CueRepeat(.weekly([2]), hour: 9, minute: 0),
                    task: task.id)
            }
            let schedule = try await store.cueSchedules().first?.line
            return [
                Check(.result, "开工了这件任务", eval.rig.app.host.calls.contains { if case .open = $0 { true } else { false } }),
                Check(.result, "没 done 这件任务", eval.calls("task", "done").isEmpty),
                Check(.result, "定时还在、排到下一次", schedule.flatMap(\.remindAt).map { $0 > .now } == true),
                Check(.interrupt, "没打扰他（没 urgent）", !eval.calls("tell").contains { $0.args["urgent"] as? Bool == true }),
            ]
        }
    }

    static let pushReady = """
        忘记密码做好了，已提交到本地 main（3f9c2ab）。
        ```
        $ npm test
        Tests: 23 passed, 23 total
        $ npm run lint
        ✔ No problems
        ```
        """
}
#endif
