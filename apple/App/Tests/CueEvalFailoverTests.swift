#if os(macOS)
import CueAgent
import CuePi
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 自动换大脑之后换上的那家真能接着干：Cue 用假模型的 Pi 值班、这一轮报额度用完，这台 Mac 上另记着一家真的 Agent（`EvalBrain.current`，
/// 用 `CUEPAD_CUE_EVAL_RUNTIME` 选，不能是 Pi）。他发一条消息 → 管理器换过去、只说一次 → 真的大脑起来、调 Cue 的工具办了这件事并回他。
/// 只在 `CUEPAD_CUE_EVAL=1` 时跑，跑法见 docs/cue-eval.md「换大脑」。
@Suite(.enabled(if: evalEnvironment["CUEPAD_CUE_EVAL"] == "1", "CUEPAD_CUE_EVAL=1 才跑"), .timeLimit(.minutes(10)))
struct CueEvalFailoverTests {
    @Test func 额度用完_换到真的另一家接着答() async throws {
        let to = EvalBrain.current
        try #require(to.runtime != .pi, "换上的那家要是 Pi 以外的真 Agent：CUEPAD_CUE_EVAL_RUNTIME=codex 或缺省的 Claude Code")
        try await CueEval.run("换大脑", expect: "Pi 额度用完：换到 \(to.runtime.name)、只说一次，新的大脑调工具建任务并回他", rig: {
            try await CueHostTests.Rig(standby: to)
        }) { eval in
            let rig = eval.rig
            try await rig.store.recordMacAgents(
                host: TestApp.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: []), MacAgent(kind: to.runtime, model: nil, models: [])])
            rig.model.blockQuota(times: 1)
            let said = "在演示项目里建个任务「整理周报」，先别开工"
            let woke = try #require(try await eval.settle { try await rig.say(said) }, "Cue 没醒")
            let rounds = eval.rounds.filter { woke.contains($0.startedAt) }
            let added = CueEval.calls(in: rounds, "task", ["add"]).filter { !$0.call.failed }
            let profile = try await rig.store.cueProfile()
            let health = rig.health
            let replies = try await eval.said().filter { $0.author == .known(.cue) && !$0.text.contains("接着干") }
            let tasks = try await rig.store.cueBoard().tasks.map(\.task)
            let switched = try await rig.count("我换到 \(to.runtime.name) 接着干"), errors = try await rig.count("这一轮出错了")
            let delivered = try await rig.store.cueMessages().first { $0.text == said }?.deliveredAt != nil
            return [
                Check(.result, "设置换到 \(to.runtime.name)（模型清空、fast 关）",
                      profile?.runtime == .known(to.runtime) && profile?.model == nil && profile?.fast == false),
                Check(.result, "健康：值班中、用着 \(to.runtime.name)、记着从 Pi 换过来",
                      health?.phase == .running && health?.runtime == to.runtime && health?.failover?.from == .pi && health?.failover?.to == to.runtime),
                Check(.interrupt, "换大脑只说一次、不报那个错", switched == 1 && errors == 0),
                Check(.result, "第一轮记着额度的错、之后有一轮好好做完", rounds.first?.failure != nil && rounds.contains { $0.finishedAt != nil && $0.failure == nil }),
                Check(.tool, "新的大脑调 Cue 的工具建了任务", !added.isEmpty && tasks.contains { $0.heading.contains("周报") }),
                Check(.result, "他的话交给了新的大脑", delivered),
                Check(.result, "回了他这句", !replies.isEmpty, note: replies.last.map { "：\($0.text)" } ?? ""),
            ]
        }
    }
}
#endif
