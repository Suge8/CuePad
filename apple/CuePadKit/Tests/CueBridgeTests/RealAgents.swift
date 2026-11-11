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
/// - claude：Anthropic Messages（`ClaudeTestbed`），假密钥、关辅助流量；
/// - grok：Responses；
/// - dsh：Messages，经 `DEEPSEEK_BASE_URL`（搜索的 `DEEPSEEK_SEARCH_BASE_URL` 也指过去），key 是假的；
/// - opencode：Chat Completions，在隔离的 `OpenCodeSandbox` 里。
///
/// 没装的家跳过，原因以「未覆盖：」开头（`PinnedAgent.uncovered`，xc.sh 在汇总后单列，不算通过）：只连一家的套件整套跳过（`needs`），
/// 按家参数化的用例跳过那一例（`require`）。完整矩阵（`CUEPAD_AGENT_MATRIX=full`，CI 与 `xc.sh signoff`）不跳过，缺一家就红。
///
/// 分两档：默认只跑打了 `.smoke` 标签的（每家起来、说一句、收到回复、停下，加那一家独有的握手），哪条是冒烟只看这个标签；
/// `CUEPAD_AGENT_TESTS=all`（CI；`xc.sh test` 点名 Real 开头的套件时也是）跑全量。
/// 每个 Real 开头的套件都挂 `tiered`：没跑的照样以「未覆盖：」跳过，不算通过。
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

    static let everything = ProcessInfo.processInfo.environment["CUEPAD_AGENT_TESTS"] == "all"

    /// 跳过借 `ConditionTrait` 的 `prepare`：自己抛的错算失败，它抛的才记成跳过（带原因，结论页认得出）
    struct Tiered: SuiteTrait, TestTrait {
        var isRecursive: Bool { true }

        func prepare(for test: Test) async throws {
            guard !test.isSuite, !everything, !test.tags.contains(.smoke) else { return }
            try await ConditionTrait.disabled("未覆盖：真 Agent 的全量用例，这一档只跑冒烟（TEST_RUNNER_CUEPAD_AGENT_TESTS=all 跑全量）").prepare(for: test)
        }
    }

    static let tiered = Tiered()

    /// 按家参数化的用例第一句调
    static func require(_ agent: AgentKind) throws {
        if let reason = pinned(agent).uncovered { try Test.cancel(Comment(rawValue: reason)) }
    }
}

extension Tag {
    /// 真 Agent 的冒烟（`RealAgents.Tiered`）
    @Tag static var smoke: Self
}

let fixturesDirectory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)
#endif
