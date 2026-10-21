#if os(macOS)
import CueStore
import CryptoKit
import CueTestSupport
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CuePi

/// 套件上的录像带：每个用例（参数化的每组参数）一盘，模式见 `RealAgents`。
struct AgentTapeTrait: SuiteTrait, TestTrait, TestScoping {
    let agent: AgentKind?
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> AgentTapeTrait? { testCase == nil ? nil : self }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        let tape = try AgentTape(agent: agent, test: test)
        try await AgentTape.$current.withValue(tape) {
            do {
                try await function()
            } catch {
                await tape.finish(keep: false)
                throw error
            }
            await tape.finish()
        }
    }
}

extension Trait where Self == AgentTapeTrait {
    /// 这家的真 Agent 用例：默认回放录像带，`CUEPAD_AGENT_TESTS` 列出这家时连真 Agent 跑并重录。
    static func agentTape(_ agent: AgentKind) -> Self { AgentTapeTrait(agent: agent) }
    /// 几家共用的套件：用例里用 `AgentTape.use(_:variant:)` 给出这一盘是哪家的。
    static var agentTapes: Self { AgentTapeTrait(agent: nil) }
}
#endif
