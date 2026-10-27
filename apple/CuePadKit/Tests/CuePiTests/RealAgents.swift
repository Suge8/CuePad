#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing

/// 真 Agent 用例（Pi、Codex、Claude Code、OpenCode 的托管、钩子、大脑与开工）的跑法，唯一的一处。
///
/// 默认回放：每个用例读 `Fixtures/tapes/<家>/<套件>/<用例>[ <参数>].jsonl` 里录好的 Agent 输出（`AgentTape`），不起真 Agent、
/// 不联网、不花钱，断言照旧。录在 CuePad 读 Agent 输出的边界：Agent 进程的标准输入输出、信号与退出（CuePad 起的是替身
/// `Fixtures/tape-stub.c`）、Pi 扩展的会话 socket、钩子 socket、Agent 写出的会话文件与工作目录里的产物。
/// CuePad 发给 Agent 的与录下的逐项比对，对不上就报"重录"。
///
/// 录制：列出要录的几家（`AgentKind` 的 rawValue），这几家连真 Agent 跑同样的断言，并重写它们的录像带：
///
///     TEST_RUNNER_CUEPAD_AGENT_TESTS=pi,codex,claude apple/scripts/xc.sh test kit -only-testing:CuePiTests
///
/// 下面的变量同样加 `TEST_RUNNER_` 前缀给（xcodebuild 只把这样的变量交给测试进程）。
///
/// - pi：`~/.local/bin/pi`，假模型（`Fixtures/fake-model.ts`），零网络；FireCode 用例另要本机的 FireCode 源码（`CUEPAD_FIRECODE_SOURCE` 可换）；
/// - codex：本机的 codex 与登录（复制进临时目录且不刷新，见 `copyCodexAuth`），账号里最便宜的模型；
/// - claude：本机的 claude 与它自己的登录（钥匙串里的那条，见 `ClaudeLogin`），模型 haiku（`ClaudeTestbed`）；
/// - 大脑（`RealBrainTests`）用本机用户自己的登录，模型用 `CUEPAD_BRAIN_MODEL_<家>`、强度用 `CUEPAD_BRAIN_EFFORT` 换。
///
/// 列出的家本机没装或没登录时，它的用例跳过、录像带不动。模型的回答每次不同，录下的一盘断言没过就再录这一个用例。
///
/// 没有录像带、只在列出这家时连真 Agent 跑的（`live(_:_:)`）：终端里的 Codex 与 Claude Code（断言的是伪终端、tmux 里真终端界面的
/// 输出与按键），大脑结束后不留进程与历史（`RealBrainProcessTests`，看的是真进程树与各家真实的历史目录），旧扩展托管进程换上新扩展（两个 Pi 进程交替上桥、热换扩展文件，回放排不稳先后），OpenCode（它的 HTTP/SSE 边界没接进录像带；
/// 本机装的 v2——官方脚本、Homebrew 或 npm 的 `@opencode/cli`——在隔离的 `OpenCodeSandbox` 里用免费模型跑，要联网；免费额度按 IP 计，
/// 用完或限流时 `CUEPAD_OPENCODE_MODEL` 写成 `提供方/模型` 换到自己的提供方，密钥只经环境给）。
enum RealAgents {
    static let recording: Set<AgentKind> = Set((ProcessInfo.processInfo.environment["CUEPAD_AGENT_TESTS"] ?? "").split(separator: ",")
        .compactMap { AgentKind(rawValue: String($0).trimmingCharacters(in: .whitespaces)) })

    static func mode(of agent: AgentKind) -> TapeMode {
        guard recording.contains(agent) else { return .replay }
        return agent == .opencode ? .live : .record
    }

    /// 录制时这家本机跑得起来（装了、登录了）
    static func installed(_ agent: AgentKind) -> Bool {
        switch agent {
        case .pi: realPiInstalled
        case .codex: realCodexURL != nil && FileManager.default.fileExists(atPath: realCodexAuth.path)
        case .claudeCode: claudeURL != nil && ClaudeLogin.token != nil
        case .opencode: realOpenCodeURL != nil
        }
    }

    /// 回放，或录制且本机跑得起来
    static func runs(_ agent: AgentKind) -> Bool { mode(of: agent) == .replay || installed(agent) }

    /// 有录像带的套件：回放总是跑，录制要本机跑得起来。
    static func taped(_ agent: AgentKind) -> ConditionTrait {
        .enabled(if: runs(agent), "CUEPAD_AGENT_TESTS 列出了 \(agent.rawValue)，但本机没装或没登录，录不了")
    }

    /// 只连真 Agent 跑的套件（没有录像带）：列出这家且本机跑得起来时才跑。
    static func live(_ agent: AgentKind, _ why: String) -> ConditionTrait {
        .enabled(if: recording.contains(agent) && installed(agent), "只连真 \(agent.rawValue) 跑（\(why)）：TEST_RUNNER_CUEPAD_AGENT_TESTS=\(agent.rawValue) 开启")
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
