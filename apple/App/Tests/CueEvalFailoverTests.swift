#if os(macOS)
import CueAgent
import CueBridge
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePad

/// 自动换大脑之后换上的那家真能接着干：Cue 用假模型的 Pi 值班、这一轮报额度用完，这台 Mac 上另记着一家真的 Agent（`EvalBrain.current`，用 `CUEPAD_CUE_EVAL_RUNTIME` 选，不能是 Pi）。
/// 只在 `CUEPAD_CUE_EVAL=1` 时跑，跑法见 docs/cue-eval.md「换大脑」。
@Suite(.releasesLibraries, .enabled(if: evalEnvironment["CUEPAD_CUE_EVAL"] == "1", "CUEPAD_CUE_EVAL=1 才跑"), .timeLimit(.minutes(10)))
struct CueEvalFailoverTests {
    @Test func 额度用完_换到真的另一家接着答() async throws {
        let to = EvalBrain.current
        try #require(to.runtime != .pi, "换上的那家要是 Pi 以外的真 Agent：CUEPAD_CUE_EVAL_RUNTIME=codex 或缺省的 Claude Code")
        try await CueEval.run("换大脑", expect: "Pi 额度用完：换到 \(to.runtime.name)、只说一次，新的大脑调工具在演示建「整理周报」、不开工，并回他这件事", rig: {
            try await CueHostTests.Rig(standby: to)
        }) { eval in
            let rig = eval.rig
            try await rig.store.recordMacAgents(
                host: TestApp.hostID, name: "测试 Mac", [MacAgent(kind: .pi, model: nil, models: []), MacAgent(kind: to.runtime, model: nil, models: [])])
            rig.model.blockQuota(times: 1)
            let said = "在演示项目里建个任务「整理周报」，先别开工"
            let woke = try #require(try await eval.settle { try await rig.say(said) }, "Cue 没醒")
            let rounds = eval.rounds.filter { woke.contains($0.startedAt) }
            let failed = rounds.first?.failure.map(ErrorSummary.init)
            let answered: CueRound? = rounds.last { (round: CueRound) -> Bool in round.wake == .message && round.finishedAt != nil && round.failure == nil }
            let added = CueEval.calls(in: answered.map { [$0] } ?? [], "task", ["add"]).filter { CueEval.built($0.call) }
            var reply: CueMessage?
            if let answered, let finished = answered.finishedAt {
                reply = try await eval.said(since: answered.startedAt).last { (message: CueMessage) -> Bool in
                    message.author == .known(.cue) && message.choices == nil && message.taskID == nil && message.createdAt <= finished + 0.001
                }
            }
            let profile = try await rig.store.cueProfile()
            let health = rig.health
            let tasks = try await rig.store.cueBoard().tasks.map(\.task)
            let demo = try await rig.store.projects().first { $0.name == "演示" }
            let switched = try await rig.count("我换到 \(to.runtime.name) 接着干"), errors = try await rig.count("这一轮出错了")
            let delivered = try await rig.store.cueMessages().first { $0.text == said }?.deliveredAt != nil
            return [
                Check(.result, "设置换到 \(to.runtime.name)（模型清空、fast 关）",
                      profile?.runtime == .known(to.runtime) && profile?.model == nil && profile?.fast == false),
                Check(.result, "第一轮报的是额度用完", failed?.kind == .quota, note: rounds.first?.failure.map { "：\($0)" } ?? ""),
                Check(.result, "健康：值班中、用着 \(to.runtime.name)、记着因额度用完从 Pi 换过来",
                      health?.phase == .running && health?.runtime == to.runtime && health?.failover?.from == .pi && health?.failover?.to == to.runtime
                          && failed.map { health?.failover?.reason == $0.title } == true),
                Check(.interrupt, "换大脑只说一次、不报那个错", switched == 1 && errors == 0),
                Check(.result, "他的话交给了新的大脑", delivered),
                Check(.tool, "新的大脑调 Cue 的工具建了这件任务", !added.isEmpty),
                Check(.result, "只有一件、标题是整理周报、在演示、没开工",
                      tasks.count == 1 && tasks.first?.heading.contains("周报") == true && tasks.first?.projectID == demo?.id
                          && !rig.app.host.calls.contains { if case .open = $0 { true } else { false } }),
                Check(.result, "这一轮回了他这件事已办好（不是出错、没办成的话）",
                      reply.map { $0.text.contains("周报") && $0.text.contains(/建好|建了|已建|加了|记下/)
                          && !$0.text.contains(/出错|失败|没能|用不了|还没建|稍后|再试|无法/) } == true,
                      note: reply.map { "：\($0.text)" } ?? ""),
            ]
        }
    }
}
#endif
