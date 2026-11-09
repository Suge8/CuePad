#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing

/// 真 Agent 用例（Pi、Codex、Claude Code、OpenCode、Grok Build、dsh 的托管、钩子、大脑与开工）的跑法，唯一的一处。
///
/// 默认回放：每个用例读 `Fixtures/tapes/<家>/<套件>/<用例>[ <参数>].jsonl` 里录好的 Agent 输出（`AgentTape`），不起真 Agent、
/// 不联网、不花钱，断言照旧。录在 CuePad 读 Agent 输出的边界：Agent 进程的标准输入输出、信号与退出（CuePad 起的是替身
/// `Fixtures/tape-stub.c`）、Pi 扩展的会话 socket、钩子 socket、Agent 写出的会话文件与工作目录里的产物。
/// CuePad 发给 Agent 的与录下的逐项比对，对不上就报"重录"。
///
/// 录制：列出要录的几家（`AgentKind` 的 rawValue），这几家连真 Agent 跑同样的断言，并重写它们的录像带：
///
///     TEST_RUNNER_CUEPAD_AGENT_TESTS=codex,grok apple/scripts/xc.sh test kit -only-testing:CuePiTests
///
/// 下面的变量同样加 `TEST_RUNNER_` 前缀给（xcodebuild 只把这样的变量交给测试进程）。
///
/// - pi：没有录像带，总连钉住的真 Pi（`PinnedAgent.pi`，`xc.sh agents install pi`；没装时跳过、列为未覆盖），模型是本用例的假模型
///   （`FakeModel`，Chat Completions），零网络；FireCode 随 Pi 钉住（`CUEPAD_FIRECODE_SOURCE` 可换成另一份检出）；
/// - codex：没有录像带，总连钉住的真 Codex（`PinnedAgent.codex`，`xc.sh agents install codex`；没装时跳过、列为未覆盖），模型是本用例的假模型
///   （`FakeModel`，Responses，经隔离 `CODEX_HOME/config.toml` 的 `model_providers` 指过去），零网络、不用任何登录；
/// - claude：没有录像带，总连钉住的真 Claude Code（`PinnedAgent.claude`），模型是测试台的假模型（`FakeModel`，Anthropic Messages，`ClaudeTestbed`），
///   假密钥、不带订阅登录、关辅助流量，零网络；终端里的 Claude Code 也是它（要 tmux）；
/// - grok：没有录像带，总连钉住的真 Grok（`PinnedAgent.grok`，`xc.sh agents install grok`；没装时跳过、列为未覆盖），模型是本用例的假模型
///   （`FakeModel`，Responses），零网络、不用任何登录；
/// - dsh：没有录像带，总连钉住的真 dsh（`PinnedAgent.dsh`，`xc.sh agents install dsh`；没装时跳过、列为未覆盖），模型是本用例的假模型
///   （`FakeModel`，Messages，经 `DEEPSEEK_BASE_URL`；搜索的地址 `DEEPSEEK_SEARCH_BASE_URL` 也指过去），key 是假的，零网络；
/// - 大脑（`RealBrainTests`）除 Pi、Codex、OpenCode、dsh、Grok、Claude Code（假模型，剧本 `playBrain`、`playGrokBrain`）外用本机用户自己的登录，模型用 `CUEPAD_BRAIN_MODEL_<家>`、强度用 `CUEPAD_BRAIN_EFFORT` 换。
///
/// 列出的家本机没装或没登录时，它的用例跳过、录像带不动。模型的回答每次不同，录下的一盘断言没过就再录这一个用例。
///
/// OpenCode 没有录像带，总连钉住的真 OpenCode v2（`PinnedAgent.opencode`，`xc.sh agents install opencode`；没装时跳过、列为未覆盖），
/// 在隔离的 `OpenCodeSandbox` 里连本用例的假模型（`FakeModel`，Chat Completions），零网络。
///
/// 没有录像带、只在列出这家时连真 Agent 跑的（`live(_:_:)`）：终端里的 Codex（断言的是伪终端里真终端界面的
/// 输出与按键），大脑结束后不留进程与历史（`RealBrainProcessTests`，看的是真进程树与各家真实的历史目录；Pi、OpenCode、dsh、Grok、Claude Code 的总跑），
/// 旧扩展托管进程换上新扩展（两个 Pi 进程交替上桥、热换扩展文件，回放排不稳先后）。
enum RealAgents {
    static let recording: Set<AgentKind> = Set((ProcessInfo.processInfo.environment["CUEPAD_AGENT_TESTS"] ?? "").split(separator: ",")
        .compactMap { AgentKind(rawValue: String($0).trimmingCharacters(in: .whitespaces)) })

    static func mode(of agent: AgentKind) -> TapeMode {
        if [.opencode, .pi, .codex, .grok, .dsh, .claudeCode].contains(agent) { return .live }
        return recording.contains(agent) ? .record : .replay
    }

    /// 连真 Agent 跑不起来的原因（没装、没登录、缺模型）；跑得起来为 nil
    static func missing(_ agent: AgentKind) -> String? {
        switch agent {
        case .pi: pinnedPi.uncovered
        case .codex: pinnedCodex.uncovered
        case .claudeCode: pinnedClaude.uncovered
        case .opencode: OpenCodeSandbox.pinned.uncovered
        case .grok: pinnedGrok.uncovered
        case .dsh: PinnedAgent.dsh.uncovered
        }
    }

    static func runs(_ agent: AgentKind) -> Bool { mode(of: agent) == .replay || missing(agent) == nil }

    static func taped(_ agent: AgentKind) -> ConditionTrait {
        .enabled(if: runs(agent), "\(agent.rawValue) 跑不了：\(missing(agent) ?? "")")
    }

    static func live(_ agent: AgentKind, _ why: String) -> ConditionTrait {
        .enabled(if: recording.contains(agent) && missing(agent) == nil, "只连真 \(agent.rawValue) 跑（\(why)）：TEST_RUNNER_CUEPAD_AGENT_TESTS=\(agent.rawValue) 开启")
    }

    /// 有录像带的套件的时限：录制时给真 Agent 的 `recording`；回放不另设，用 xc.sh 给每个测试的统一时限
    /// （各用例自己再设一个更短的墙钟时限，机器忙时会先于它到点，成了假失败）。
    static func timeLimit(_ recording: TimeLimitTrait.Duration) -> any SuiteTrait {
        Self.recording.isEmpty ? ConditionTrait.enabled(if: true) : .timeLimit(recording)
    }

    /// 回放时套件内并行（快），录制时一个一个来（真 Agent 抢同一份额度与常驻服务）。
    static func serialWhenRecording(_ agents: AgentKind...) -> any SuiteTrait {
        agents.contains(where: recording.contains) ? ParallelizationTrait.serialized : ConditionTrait.enabled(if: true)
    }
}
#endif
