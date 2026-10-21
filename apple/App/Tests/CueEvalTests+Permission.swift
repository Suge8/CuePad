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
    /// issue #26：没配置过的 Codex 在只读沙箱里，写工作区里的文件前申请权限（原话照它的申请写），在工作区里写文件不属于先问的那几类。
    @Test func p权限确认工作区写文件() async throws {
        try await CueEval.run(
            "p-权限确认工作区写文件",
            expect: "会话在只读沙箱里申请在工作区建 hello.txt：Cue 自己答允许，不拒绝、不问他"
        ) { eval in
            let rig = eval.rig
            let work = try await rig.working("创建问候文件", "在当前工作区创建 hello.txt，内容为一行 hello。完成后提供文件路径及读回的原文作为证据。")
            let question = "允许 Codex 运行命令？\nprintf 'hello\\n' > hello.txt\n当前环境为只读沙箱，是否允许在工作区创建 hello.txt？"
            try await eval.trigger {
                try await rig.store.writePiTranscript(PiTranscript(
                    sessionID: work.id, messages: [work.prompt, rig.reply(work, "我会创建 `hello.txt`，然后读回内容作为证据。")],
                    recap: PiRecap(pendingPrompt: oneLine(work.prompt.text))))
                work.session.sendInfo(["question": ["id": "p1", "kind": "confirm", "text": question]])
                work.session.setState(["kind": "waiting_user", "title": question])
            }
            let answers = work.session.commands.filter { $0.json["t"] as? String == "answer" }.compactMap { $0.json["value"] as? Bool }
            return [
                Check(.result, "答了允许", answers == [true]),
                Check(.interrupt, "没打扰他（没 tell）", eval.calls("tell").isEmpty),
            ]
        }
    }

    /// issue #26 里派出的第一件事：他说的工作区是项目的文件夹，不是大脑自己的工作目录（Cue 的 work，空的、不归他）。
    @Test func v在工作区建文件() async throws {
        try await CueEval.run("v-在工作区建文件", expect: "他要在工作区里建 hello.txt：建任务开工，正文不把文件指到 Cue 自己的工作目录") { eval in
            let rig = eval.rig
            try await eval.trigger { try await rig.say("在工作区里建一个 hello.txt，写一句 hello") }
            let tasks = try await rig.store.cueBoard().tasks.map(\.task)
            return [
                Check(.result, "开工（开出了会话）", rig.app.host.calls.contains { if case .open = $0 { true } else { false } }),
                Check(.result, "正文没指到 Cue 的工作目录", !tasks.isEmpty && tasks.allSatisfy { !$0.body.contains("Cue/work") }),
            ]
        }
    }
}
#endif
