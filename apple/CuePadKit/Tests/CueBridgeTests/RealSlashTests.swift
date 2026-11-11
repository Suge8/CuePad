#if os(macOS)
import CueTestSupport
import Foundation
import Testing
import CueStore
@testable import CueBridge

/// 提示词模板与 skill 用 Pi 的显式路径参数加载，扩展命令来自测试夹具。
@MainActor
@Suite(RealAgents.needs(.pi), RealAgents.tiered)
struct RealSlashTests {
    private func withRig(_ body: (PiProcess, Bridge, Session) async throws -> Void) async throws {
        let resources = try makeTempDirectory()
        let prompts = resources.appending(path: "prompts")
        let skill = resources.appending(path: "skills/careful")
        try FileManager.default.createDirectory(at: prompts, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: skill, withIntermediateDirectories: true)
        try "---\ndescription: Greet someone\n---\nSay hello to $1.\n".write(to: prompts.appending(path: "greet.md"), atomically: true, encoding: .utf8)
        try "---\nname: careful\ndescription: Work carefully\n---\nCAREFUL-BODY-MARKER\n".write(
            to: skill.appending(path: "SKILL.md"), atomically: true, encoding: .utf8)
        let pi = try await PiProcess(
            extraExtensions: ["ui-confirm.ts", "slash.ts"],
            extraArguments: ["--prompt-template", prompts.path, "--skill", skill.deletingLastPathComponent().path])
        let bridge = Bridge(socketDirectory: pi.paths.socketDirectory)
        defer { bridge.stop(); pi.stop() }
        try bridge.start()
        try await eventually("桥发现真实 Pi 会话") { !bridge.sessions.isEmpty }
        try await body(pi, bridge, bridge.sessions[0])
    }

    @Test func contextUsageIsReportedPerTurnAndUnknownRightAfterCompaction() async throws {
        try await withRig { pi, bridge, s in
            #expect(s.context?.window == 100_000)
            await #expect(throws: BridgeError.self) { try await bridge.command("/compact", in: s.id) }  // 太短没有可压缩的：失败报给发起方，不静默

            // 压缩要有足够多的历史：留下最近约 2 万 token，更早的才压成摘要
            var used = 0
            for round in 1...2 {
                try pi.prompt("第 \(round) 轮 " + String(repeating: "上下文填充 ", count: 12_000))
                // 以已用量涨上去为准：上一轮的"歇下"状态在新一轮开始前还留着，单看状态会提前放行
                try await eventually("第 \(round) 轮之后已用量涨了") {
                    (bridge.sessions.first?.context?.tokens ?? 0) > used + 10_000 && bridge.sessions.first?.state == .settled
                }
                used = bridge.sessions.first?.context?.tokens ?? 0
            }
            #expect(used > 40_000 && used < 100_000)

            try await bridge.command("/compact", in: s.id)
            try await eventually("压缩后已用量未知") {
                bridge.sessions.first?.context.map { $0.tokens == nil && $0.window == 100_000 } == true
            }
            let transcript = try History.index(file: #require(s.sessionFile), from: nil).messages
            #expect(transcript.contains { $0.role == .known(.system) && $0.text.hasPrefix("已压缩上下文") })
            #expect(transcript.filter { $0.role == .known(.user) }.count == 2)  // 命令没有变成你说的话
        }
    }

    @Test func commandListHasRunnableBuiltinsExtensionsTemplatesAndSkills() async throws {
        try await withRig { _, _, s in
            let byName = Dictionary(uniqueKeysWithValues: s.commands.map { ($0.name, $0) })
            for builtin in ["compact", "name", "model", "thinking", "new", "reload", "clone"] {
                #expect(byName[builtin]?.source == .known(.builtin), "\(builtin)")
            }
            #expect(byName["shout"]?.source == .known(.extension) && byName["shout"]?.summary == "test: shout the arguments")
            #expect(byName["greet"]?.source == .known(.prompt) && byName["greet"]?.summary == "Greet someone")
            #expect(byName["skill:careful"]?.source == .known(.skill) && byName["skill:careful"]?.summary == "Work carefully")
            #expect(byName["compact"]?.hint != nil && byName["new"]?.hint == nil)
            for terminalOnly in ["settings", "tree", "fork", "resume", "login", "hotkeys", "cuepad-reload", "cuepad"] {
                #expect(byName[terminalOnly] == nil, "\(terminalOnly)")
            }
        }
    }

    @Test func extensionCommandsAreConfirmedAndTemplatesAndSkillsLandWithTheirDelivery() async throws {
        try await withRig { pi, bridge, s in
            try await bridge.command("/shout hi there", in: s.id)
            _ = try await pi.waitForEvent("扩展命令跑了") { $0["method"] as? String == "notify" && $0["message"] as? String == "shout:hi there" }
            #expect(fileTexts("user", in: s.sessionFile).isEmpty, "扩展命令不产生发给模型的消息")

            let greet = UUID(), careful = UUID()
            try await bridge.send(SessionMessage(text: "/greet world", deliveryID: greet.uuidString), to: s.id)
            try await eventually("模板展开后进了模型上下文") { fileTexts("user", in: s.sessionFile) == ["Say hello to world."] }
            // 回复框带着卡片发时卡片接在你打的话后面（`Slash.said`）：仍按 skill 展开，卡片是参数
            try await bridge.send(SessionMessage(text: "/skill:careful 小心点\n\n卡片：登录页改版", deliveryID: careful.uuidString), to: s.id)
            try await eventually("skill 展开后进了模型上下文") {
                fileTexts("user", in: s.sessionFile).last.map { $0.contains("CAREFUL-BODY-MARKER") && $0.hasSuffix("小心点\n\n卡片：登录页改版") } == true
            }
            let said = try History.index(file: #require(s.sessionFile), from: nil).messages.filter { $0.role == .known(.user) }
            #expect(said.map(\.deliveryID) == [greet, careful])
        }
    }

    @Test func unknownAndMalformedCommandsAreRefused() async throws {
        try await withRig { _, bridge, s in
            await #expect(throws: BridgeError.rejected("unknown_command")) { try await bridge.command("/nope", in: s.id) }
            await #expect(throws: BridgeError.rejected("unknown_command")) { try await bridge.command("/settings", in: s.id) }  // 纯终端交互的内置命令
            await #expect(throws: BridgeError.rejected("bad_request")) { try await bridge.command("hello", in: s.id) }
            await #expect(throws: BridgeError.rejected("missing_argument")) { try await bridge.command("/name", in: s.id) }
            await #expect(throws: BridgeError.unknownModel(.pi)) { try await bridge.command("/model fake/nope", in: s.id) }
            await #expect(throws: BridgeError.rejected("bad_request")) { try await bridge.command("/thinking ultra", in: s.id) }
        }
    }

    @Test func builtinNameModelAndThinkingTakeEffect() async throws {
        try await withRig { _, bridge, s in
            try await bridge.command("/name 登录修复", in: s.id)
            try await eventually("改名") { bridge.sessions.first?.displayName == "登录修复" }

            try await bridge.command("/model fake/echo-think", in: s.id)
            try await eventually("换模型") { bridge.sessions.first?.model?.key.id == "echo-think" }
            try await bridge.command("/thinking high", in: s.id)
            try await eventually("换强度") { bridge.sessions.first?.thinking == .known(.high) }
            try await bridge.command("/model echo-b", in: s.id)  // 不带提供方：模型 id 唯一时也认
            try await eventually("按 id 换模型") { bridge.sessions.first?.model?.key.id == "echo-b" }
        }
    }

    @Test func newSessionEndsTheOldOneAndOpensAnother() async throws {
        try await withRig { pi, bridge, s in
            let log = ChangeLog(bridge)
            try pi.prompt("先说一句")
            try await eventually("回复写入") { fileTexts("user", in: s.sessionFile) == ["先说一句"] }
            try await eventually("歇下") { bridge.sessions.first?.state == .settled }

            try await bridge.command("/new", in: s.id)
            try await eventually("新会话") { bridge.sessions.count == 1 && bridge.sessions[0].sessionID != s.sessionID }
            try await eventually("日志记下了") { log.ended.contains { $0.0.id == s.id } }
            #expect(bridge.sessions[0].commands.contains { $0.name == "shout" }, "新会话照样报告命令清单")
        }
    }

    @Test func reloadKeepsTheSessionAndReportsCommandsAgain() async throws {
        try await withRig { _, bridge, s in
            let log = ChangeLog(bridge)
            try await bridge.command("/reload", in: s.id)
            try await eventually("重载后同一会话重新连上") {
                !log.ended.isEmpty && bridge.sessions.first?.sessionID == s.sessionID && bridge.sessions.first?.commands.isEmpty == false
            }
        }
    }

    @Test func cloneOpensACopyOfTheSession() async throws {
        try await withRig { pi, bridge, s in
            try pi.prompt("要克隆的一句")
            try await eventually("答完歇下") { recap(of: s)?.lastReply != nil && bridge.sessions.first?.state == .settled }
            try await bridge.command("/clone", in: s.id)
            try await eventually("克隆出新会话") { bridge.sessions.count == 1 && bridge.sessions[0].sessionID != s.sessionID }
            try await eventually("克隆带着历史") { fileTexts("user", in: bridge.sessions[0].sessionFile) == ["要克隆的一句"] }
        }
    }
}
#endif
