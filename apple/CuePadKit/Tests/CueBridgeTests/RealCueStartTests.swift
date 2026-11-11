#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

/// 再说一句又做完歇下。各家用自己的隔离测试台：Pi、Codex、Claude Code 与 Grok Build 是假模型，OpenCode 见 `OpenCodeSandbox`，
/// dsh 的家目录在临时目录里、登录只经环境里的 DeepSeek key。

@MainActor
@Suite(RealAgents.tiered)
struct RealCueStartTests {
    @Test(.tags(.smoke), arguments: AgentKind.allCases) func cueStartsASessionTalksAndItSettles(_ agent: AgentKind) async throws {
        try RealAgents.require(agent)
        try await withAgent(agent) { runtime, bridge, work, model in
            // 强度给的不是测试台配置里的 low：生效了才看得出来
            let id = try await runtime.open(in: work, launchToken: "cue-1", name: "Cue 开的", model: model, thinking: .medium)
            let opened = try #require(bridge.session(id: id))
            #expect(opened.hosted && opened.agent == agent && opened.launchToken == "cue-1")
            try await eventually("名字、模型与强度生效") {
                let session = bridge.session(id: id)
                return session?.displayName == "Cue 开的" && session?.model?.key == model
                    && session?.thinking == .known(ThinkingLevel.medium.clamped(to: session?.model?.thinkingLevels ?? []))
            }

            if agent != .pi && agent != .codex {
                await #expect(throws: BridgeError.unsupported) {
                    try await bridge.configure(SessionConfig(fast: true, name: "不能改名"), in: id)
                }
                #expect(bridge.session(id: id)?.displayName == "Cue 开的")
            }

            for line in ["Reply with exactly the word READY.", "Reply with exactly the word AGAIN."] {
                let log = ChangeLog(bridge)
                try await bridge.send(SessionMessage(text: line), to: id)
                try await eventually("这一轮做完歇下") {
                    log.states.contains { $0.hasPendingWork } && bridge.session(id: id)?.state == .settled
                }
            }
            if agent != .opencode {
                let file = try #require(bridge.session(id: id)?.sessionFile)
                let used = try #require(Self.used(in: file, agent), "会话文件里没记下用的模型")
                // Claude Code 的别名（sonnet）在会话文件里记成它解析到的完整 id（claude-sonnet-…）
                #expect(agent == .claudeCode ? used.model?.hasPrefix("claude-\(model.id)") == true : used.model == model.id, "\(used)")
                let levels = bridge.session(id: id)?.model?.thinkingLevels ?? []
                if agent != .pi && agent != .grok { #expect(used.effort == ThinkingLevel.medium.clamped(to: levels).rawValue, "\(used)") }
            }
        }
    }

    /// 会话文件里最后一次模型请求记下的模型与强度（各家自己写的）：Claude Code 是回答上的 `model`、`effort`，Codex 是 `turn_context`，
    /// Pi 是回答上的 `model`，Grok Build 是你的话上的 `_meta.modelId`（强度不记），dsh 是请求头 `request/header` 的 `config`。
    /// OpenCode 的会话在它的库里，看会话上报的就够了。
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
        case .grok:
            return lines.first { $0["params"]?["update"]?["sessionUpdate"]?.string == "user_message_chunk" }
                .map { ($0["params"]?["update"]?["_meta"]?["modelId"]?.string, nil) }
        case .dsh:
            return lines.first { $0["type"]?.string == "request/header" }.map { line in
                let config = line["data"]?["header"]?["config"]
                return (config?["model"]?.string, config?["reasoningEffort"]?.string)
            }
        case .opencode:
            return nil
        }
    }

    private func withAgent(
        _ agent: AgentKind, _ body: (any AgentRuntime, Bridge, URL, ModelKey) async throws -> Void
    ) async throws {
        switch agent {
        case .pi:
            let pi = try await PiProcess()
            let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
            defer { stopHostedProcesses(bridge); bridge.stop(); pi.stop() }
            try bridge.start()
            let runtime = PiRuntime(bridge: bridge, paths: pi.paths, cleansInstalledExtension: true, pi: { pinnedPi.executable }, idleLimit: .seconds(120), timing: noDeadline)
            runtime.start()
            try await body(runtime, bridge, pi.cwd, ModelKey(provider: "fake", id: "echo"))
        case .codex:
            try await withCodexRig { rig in
                try await body(rig.runtime, rig.bridge, rig.codex.work, ModelKey(provider: CodexModel.provider, id: codexTestModel))
            }
        case .claudeCode:
            try await ClaudeTestbed.run { testbed in
                try testbed.startConnected()
                try await body(testbed.runtime, testbed.bridge, testbed.work, ModelKey(provider: ClaudeCode.provider, id: claudeOtherModel))
            }
        case .opencode:
            let sandbox = try await OpenCodeSandbox()
            let bridge = Bridge(socketDirectory: sandbox.paths.pi.socketDirectory)
            let runtime = sandbox.runtime(bridge, try Fixture().store)
            let outcome: Result<Void, any Error>
            do {
                try runtime.start()
                try await body(runtime, bridge, sandbox.work, openCodeTestModel)
                outcome = .success(())
            } catch { outcome = .failure(error) }
            await runtime.stop()()
            try await sandbox.stop()
            try outcome.get()
        case .grok:
            try await withGrokRig { rig in
                try await body(rig.runtime, rig.bridge, rig.work, ModelKey(provider: AgentKind.grok.rawValue, id: "grok-4.5"))
            }
        case .dsh:
            try await withDshRig { rig in try await body(rig.runtime, rig.bridge, rig.work, rig.model) }
        }
    }
}
#endif
