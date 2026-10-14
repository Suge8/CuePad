#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：Cue 用这家开工、说话、歇下。后台开一个带名字、模型、强度的会话（`AgentRuntime.open`，一次生效），开场一句做完歇下，
/// 再说一句又做完歇下。各家用自己的隔离测试台：Pi 是假模型，Codex 用复制的登录（不刷新），Claude Code 用订阅令牌，OpenCode 用免费模型。
/// 要花钱，默认不跑：开关见 `RealAgents`（`CUEPAD_AGENT_TESTS` 列出的几家）。
private let enabledAgents = RealAgents.enabled

@MainActor
@Suite(.enabled(if: !enabledAgents.isEmpty, "要花钱，默认不跑：开关见 RealAgents（CUEPAD_AGENT_TESTS）"), .serialized, .timeLimit(.minutes(6)))
struct RealCueStartTests {
    @Test(arguments: enabledAgents) func cueStartsASessionTalksAndItSettles(_ agent: AgentKind) async throws {
        try await withAgent(agent) { runtime, bridge, work, model in
            // 强度给的不是测试台配置里的 low：生效了才看得出来
            let id = try await runtime.open(in: work, launchToken: "cue-1", name: "Cue 开的", model: model, thinking: .medium)
            let opened = try #require(bridge.session(id: id))
            #expect(opened.hosted && opened.agent == agent && opened.launchToken == "cue-1")
            try await eventually("名字、模型与强度生效") {
                let session = bridge.session(id: id)
                return session?.displayName == "Cue 开的" && session?.model?.key == model
                    && session?.thinking == .known(PiThinkingLevel.medium.clamped(to: session?.model?.thinkingLevels ?? []))
            }

            for line in ["Reply with exactly the word READY.", "Reply with exactly the word AGAIN."] {
                let log = ChangeLog(bridge)
                _ = try await bridge.send(PiMessage(text: line), to: id)
                try await eventually("这一轮做完歇下", timeout: .seconds(180)) {
                    log.states.contains { $0.hasPendingWork } && bridge.session(id: id)?.state == .settled
                }
            }
            if agent != .opencode {
                let file = try #require(bridge.session(id: id)?.sessionFile)
                let used = try #require(Self.used(in: file, agent), "会话文件里没记下用的模型")
                // Claude Code 的别名（sonnet）在会话文件里记成它解析到的完整 id（claude-sonnet-…）
                #expect(agent == .claudeCode ? used.model?.hasPrefix("claude-\(model.id)") == true : used.model == model.id, "\(used)")
                if agent != .pi { #expect(used.effort == "medium", "\(used)") }
            }
        }
    }

    /// 会话文件里最后一次模型请求记下的模型与强度（各家自己写的）：Claude Code 是回答上的 `model`、`effort`，Codex 是 `turn_context`，
    /// Pi 是回答上的 `model`。OpenCode 的会话在它的库里，看会话上报的就够了。
    private static func used(in file: URL, _ agent: AgentKind) -> (model: String?, effort: String?)? {
        let lines = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").reversed().lazy
            .compactMap { JSONValue.parse(Data($0.utf8)) }
        switch agent {
        case .claudeCode:
            return lines.first { $0["type"]?.string == "assistant" }.map { ($0["message"]?["model"]?.string, $0["effort"]?.string) }
        case .codex:
            return lines.first { $0["type"]?.string == "turn_context" }.map { ($0["payload"]?["model"]?.string, $0["payload"]?["effort"]?.string) }
        case .pi:
            return lines.first { $0["message"]?["role"]?.string == "assistant" }.map { ($0["message"]?["model"]?.string, nil) }
        case .opencode:
            return nil
        }
    }

    /// 起这家的隔离测试台，交出接入、桥、工作目录与开工用的模型；不论成败都停掉起的进程、删掉临时目录。
    private func withAgent(
        _ agent: AgentKind, _ body: (any AgentRuntime, PiBridge, URL, PiModelKey) async throws -> Void
    ) async throws {
        switch agent {
        case .pi:
            let pi = try await PiProcess(modelInAgentDirectory: true)
            let bridge = PiBridge(socketDirectory: pi.paths.socketDirectory)
            defer { stopHostedProcesses(bridge); bridge.stop(); pi.stop() }
            try bridge.start()
            let runtime = PiRuntime(bridge: bridge, paths: pi.paths, pi: { realPiURL }, idleLimit: .seconds(120), extraArguments: PiProcess.quietArguments)
            runtime.start()
            try await body(runtime, bridge, pi.cwd, PiModelKey(provider: "fake", id: "echo"))
        case .codex:
            try await withCodexRig { rig in
                try await body(rig.runtime, rig.bridge, rig.codex.work, PiModelKey(provider: CodexModel.provider, id: codexTestModel))
            }
        case .claudeCode:
            try await ClaudeTestbed.run { testbed in
                try testbed.runtime.start()
                try await body(testbed.runtime, testbed.bridge, testbed.work, PiModelKey(provider: ClaudeCode.provider, id: claudeOtherModel))
            }
        case .opencode:
            let sandbox = try await OpenCodeSandbox()
            let bridge = PiBridge(socketDirectory: sandbox.paths.pi.socketDirectory)
            let runtime = OpenCodeRuntime(bridge: bridge, paths: sandbox.paths, store: try Fixture().store, hostID: "mac")
            let outcome: Result<Void, any Error>
            do {
                try runtime.start()
                try await body(runtime, bridge, sandbox.work, PiModelKey(provider: "opencode", id: "big-pickle"))
                outcome = .success(())
            } catch { outcome = .failure(error) }
            await runtime.stop()()
            try await sandbox.stop()
            try outcome.get()
        }
    }
}
#endif
