#if os(macOS)
import CueAgent
import CueBridge
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
                Check(.result, "让会话照方案 2 做（说到 2 或对话里问）", said.contains { $0.contains(/2|二|对话里问/) }),
                Check(.result, "带上按钮再小一点", said.contains { $0.contains(/小/) }),
                Check(.result, "卡收起着（没放回）", card?.setAsideBy != nil),
                Check(.ask, "没再为这件事发等你", !eval.calls("tell").contains { $0.args["ask"] != nil }),
                Check(.result, "没收掉这件事（没 done）", eval.calls("task", "done").isEmpty && work.task.status != .done),
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
                Check(.tool, "没撤回", !eval.calls("tell").contains { $0.args["withdraw"] != nil }),
                Check(.tool, "放回了等你", try await eval.rig.store.cueMessagesWaitingForYou().contains { $0.id == question.id }),
                Check(.result, "回了他", try await eval.reply() != nil),
            ]
        }
    }
}
#endif
