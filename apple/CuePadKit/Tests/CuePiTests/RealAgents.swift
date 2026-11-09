#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing

/// 真 Agent 用例（Pi、Codex、Claude Code、OpenCode、Grok Build、dsh 的托管、终端、钩子、大脑与开工）的跑法，唯一的一处。
///
/// 每家都连 `Tests/agents.json` 钉住的真 Agent（`PinnedAgent`，`apple/scripts/xc.sh agents install`），模型是本用例的假模型
/// （`FakeModel`），零网络、不用任何登录：
/// - pi：Chat Completions；FireCode 随 Pi 钉住（`CUEPAD_FIRECODE_SOURCE` 可换成另一份检出）；
/// - codex：Responses，经隔离 `CODEX_HOME/config.toml` 的 `model_providers` 指过去；终端里的 Codex 跑在伪终端里；
/// - claude：Anthropic Messages（`ClaudeTestbed`），假密钥、关辅助流量；终端里的 Claude Code 要 tmux；
/// - grok：Responses；
/// - dsh：Messages，经 `DEEPSEEK_BASE_URL`（搜索的 `DEEPSEEK_SEARCH_BASE_URL` 也指过去），key 是假的；
/// - opencode：Chat Completions，在隔离的 `OpenCodeSandbox` 里。
///
/// 没装的家跳过，原因以「未覆盖：」开头（`PinnedAgent.uncovered`，xc.sh 在汇总后单列，不算通过）：只连一家的套件整套跳过（`needs`），
/// 按家参数化的用例跳过那一例（`require`）。完整矩阵（`CUEPAD_AGENT_MATRIX=full`，CI）不跳过，缺一家就红。
enum RealAgents {
    static func pinned(_ agent: AgentKind) -> PinnedAgent {
        switch agent {
        case .pi: .pi
        case .codex: .codex
        case .claudeCode: .claude
        case .opencode: .opencode
        case .grok: .grok
        case .dsh: .dsh
        }
    }

    static func needs(_ agent: AgentKind) -> ConditionTrait {
        .enabled(if: pinned(agent).uncovered == nil, Comment(rawValue: pinned(agent).uncovered ?? ""))
    }

    /// 按家参数化的用例第一句调
    static func require(_ agent: AgentKind) throws {
        if let reason = pinned(agent).uncovered { try Test.cancel(Comment(rawValue: reason)) }
    }
}

let fixturesDirectory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)
#endif
