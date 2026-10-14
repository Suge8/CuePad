#if os(macOS)
import CueStore
import Foundation
import Testing

/// 真 Agent 用例的开关，唯一的一处。默认全不跑：`swift test` 全量只用替身，不起真 Agent、不调模型与外部服务。
/// 要跑时列出 Agent（`AgentKind` 的 rawValue），只开这几家：
///
///     CUEPAD_AGENT_TESTS=pi,codex,claude,opencode swift test --filter 'Real|CodexHooks'
///
/// - pi：真 Pi 的托管、终端、斜杠命令、压缩、补写对话、预览、firecode（`realPiAvailable`），大脑与开工的 Pi 那一份；
/// - codex：真 Codex 的托管、终端与钩子判定（`realCodexAvailable`，登录复制进临时目录且不刷新，见 `copyCodexAuth`）；
/// - claude：真 Claude Code 的托管与终端（`realClaudeAvailable`，走小米网关）；
/// - opencode：真 OpenCode（`realOpenCodeURL`，免费模型）。
///
/// 大脑（`RealBrainTests`，OpenCode 不能当大脑）与开工（`RealCueStartTests`）也按这个列表逐家跑；大脑用本机用户自己的登录，
/// 模型用 `CUEPAD_BRAIN_MODEL_<家>`、强度用 `CUEPAD_BRAIN_EFFORT` 换。开了的家本机没装（或没登录）时照样跳过。
enum RealAgents {
    static let enabled: [AgentKind] = (ProcessInfo.processInfo.environment["CUEPAD_AGENT_TESTS"] ?? "").split(separator: ",")
        .compactMap { AgentKind(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }

    static func on(_ kind: AgentKind) -> Bool { enabled.contains(kind) }

    /// 跳过时的说明
    static func skipped(_ kind: AgentKind, needs: String) -> Comment {
        "真 Agent 用例默认不跑：CUEPAD_AGENT_TESTS=\(kind.rawValue) 开启，另需 \(needs)"
    }
}
#endif
