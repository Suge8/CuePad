#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// MCP 是 Fixtures/mcp-echo.mjs 替身。
/// 各家连钉住的真 Agent 与本用例的假模型（`RealAgents`）；模型、强度用下面的变量换。
private let environment = ProcessInfo.processInfo.environment
/// Pi、Codex、OpenCode、dsh、Claude Code 连本用例的假模型（`FakeModel`，剧本 `playBrain`），Grok 同（`playGrokBrain`）
private let cheapModels: [AgentKind: String] = [
    .pi: "fake/echo", .codex: codexTestModel, .claudeCode: "haiku", .opencode: AgentKind.opencode.modelRef(openCodeTestModel),
    .grok: "grok-4.6", .dsh: "deepseek-official/deepseek-flash",
]
/// 就地换到的模型：Pi 的上下文窗口与上面的不同，换没换看得出来（Codex 里两个窗口一样，Claude Code 报的是用过的模型里最大的窗口）。
/// 用 `CUEPAD_BRAIN_OTHER_MODEL_<家>` 换
private let otherModels: [AgentKind: String] = [
    .pi: "fake/echo-think", .codex: "gpt-5.6-luna", .claudeCode: "sonnet", .opencode: AgentKind.opencode.modelRef(openCodeOtherModel),
    .grok: "grok-4.5", .dsh: "deepseek-official/deepseek-v4-pro",
]
private let echoServer = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/mcp-echo.mjs")
/// 缺省 off：最便宜，Codex、Claude Code 还会走夹取
private let effort = environment["CUEPAD_BRAIN_EFFORT"].flatMap(PiThinkingLevel.init(rawValue:)) ?? .off

@MainActor
@Suite
struct RealBrainTests {
    @MainActor
    final class Rig {
        let runtime: AgentKind
        /// 随机：好在进程树与各家的历史里认出这一次
        let marker = "cue-\(UUID().uuidString.prefix(8).lowercased())"
        let directory: URL
        let echoLog: URL
        let sessions: URL
        let codename = "ZEBRA-4821"
        /// OpenCode 的隔离家目录与库：每个大脑一台（并行的几台 OpenCode 头一次同起一个库会撞上建表）
        let sandbox: OpenCodeSandbox?
        /// 连本进程假模型的家（Pi、Codex，`playBrain`）；一串 echo 调用的第二次请求停在 `chain` 上
        let model: FakeModel?
        let chain = FakeGate()
        let brain: any HostedSession
        private(set) var events: [TurnEvent] = []

        /// `executable`：换掉钉住的那份（包在 Agent 外面的壳）
        init(_ runtime: AgentKind, executable: URL? = nil) async throws {
            self.runtime = runtime
            let root = try makeTempDirectory().resolvingSymlinksInPath()
            directory = root.appending(path: marker)
            sessions = root.appending(path: "pi-sessions")
            echoLog = root.appending(path: "echo.log")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            model = [.pi, .codex, .opencode, .dsh, .grok, .claudeCode].contains(runtime) ? try await FakeModel() : nil
            if runtime == .grok { model?.playGrokBrain(chain: chain) } else { model?.playBrain(chain: chain) }
            // Claude Code 换模型前问一次服务端：没有这个模型的答 404
            if runtime == .claudeCode { model?.on({ $0.model == "no-such-model" }) { _ in .fail("model: no-such-model", status: 404) } }
            sandbox = runtime == .opencode ? try await OpenCodeSandbox(model: model) : nil
            if runtime == .pi, let model { try PiProcess.writeModels(model, into: root.appending(path: "pi-agent")) }
            if runtime == .codex, let model { try CodexHome.write(provider: model, into: root.appending(path: "codex")) }
            // Grok 的家目录与配置目录在这里，不碰真实的 ~/.grok，模型指到假模型；dsh 的家目录也在这里（模型地址与假 key 见 `DshRig.environment`）；
            // Pi 的 agent 目录也在这里，不读用户的 ~/.pi（设置、提供方各人不同）
            let agentHome = switch runtime {
            case .pi: ["PI_CODING_AGENT_DIR": root.appending(path: "pi-agent").path]
            case .claudeCode: try ClaudeTestbed.isolatedEnvironment(model: #require(model), root: root)
            case .grok: grokEnvironment(model: try #require(model), home: root.appending(path: "grok-home"), grokHome: root.appending(path: "grok-user"))
            case .dsh: try DshRig.environment(try #require(model), in: root)
            case .codex: ["HOME": root.appending(path: "user").path, "CODEX_HOME": root.appending(path: "codex").path, CodexHome.keyVariable: "fake"]
            default: [String: String]()
            }
            let config = CueBrainConfig(
                runtime: runtime, executable: executable ?? RealAgents.pinned(runtime).executable,
                model: environment["CUEPAD_BRAIN_MODEL_\(runtime.rawValue.uppercased())"] ?? cheapModels[runtime], effort: effort,
                systemPrompt: "You are Cue, a test assistant. Your codename is \(codename). Keep answers to one short sentence. When asked to echo something, call the echo tool.",
                workingDirectory: directory,
                mcp: [try #require(ExecutableLocator.standard.candidates("node").first).path, echoServer.path, marker],
                // Pi 的会话落盘位置指到这里：`--no-session` 生效的话它一直是空的（不去翻用户的 ~/.pi）
                environment: ["MCP_ECHO_LOG": echoLog.path, "PI_CODING_AGENT_SESSION_DIR": sessions.path].merging(sandbox?.environment ?? agentHome) { $1 })
            brain = try await config.startBrain()
            let events = brain.events
            Task { [weak self] in for await event in events { self?.events.append(event) } }
        }

        func count(_ event: TurnEvent) -> Int { events.filter { $0 == event }.count }

        func finished(_ n: Int = 1) async throws {
            try await eventually("第 \(n) 轮做完") { self.count(.turnFinished) >= n }
        }

        var turns: [(received: [UUID], reply: String?)] {
            var turns: [(received: [UUID], reply: String?)] = [], open: (received: [UUID], reply: String?)?, early: [UUID] = []
            for event in events {
                switch event {
                case .turnStarted:
                    open = (early, nil)
                    early = []
                case .received(let id): if open == nil { early.append(id) } else { open?.received.append(id) }
                case .speaking(let draft): open?.reply = draft?.text
                case .turnFinished:
                    if let open { turns.append(open) }
                    open = nil
                default: break
                }
            }
            return turns
        }
        var replies: [String] { turns.compactMap(\.reply) }
        var failures: [String] { events.compactMap { if case .failed(let text) = $0 { text } else { nil } } }
        var contexts: [Int] { events.compactMap { if case .context(let used, _) = $0 { used } else { nil } } }
        var echoed: [String] { ((try? String(contentsOf: echoLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    }

    func withRig(_ runtime: AgentKind, executable: URL? = nil, _ body: (Rig) async throws -> Void) async throws {
        let rig = try await Rig(runtime, executable: executable)
        let outcome: Result<Void, any Error>
        do { try await body(rig); outcome = .success(()) } catch { outcome = .failure(error) }
        await rig.brain.stop()()
        try await rig.sandbox?.stop()
        try outcome.get()
    }

    @Test(arguments: AgentKind.allCases) func aMessageGetsAReplyContextAndAFinishedTurn(_ runtime: AgentKind) async throws {
        try RealAgents.require(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("What is your codename? Reply with only the codename.")
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        // 正在说的话的清除可能落在这一轮开始之前（Claude 会），轮次的起止只看别的事件
        let turn = rig.events.filter { if case .speaking = $0 { false } else { true } }
        #expect(turn.first == .turnStarted && turn.last == .turnFinished, "\(rig.events)")
        #expect(rig.replies.count == 1 && rig.replies[0].contains(rig.codename))
        #expect(try #require(rig.contexts.last) > 0)
        }
    }

    @Test(arguments: AgentKind.allCases) func anImageIsSeen(_ runtime: AgentKind) async throws {
        try RealAgents.require(runtime)
        try await withRig(runtime) { rig in
        #expect(rig.brain.seesImages)
        try await rig.brain.send("What color is this image? Reply with only the color name in English.", images: [PiImage(mimeType: "image/png", data: redPNG)], id: UUID())
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        #expect(rig.replies.last?.lowercased().contains("red") == true, "\(rig.replies)")
        }
    }

    @Test(arguments: AgentKind.allCases) func aMessageDuringATurnJoinsThatTurn(_ runtime: AgentKind) async throws {
        try RealAgents.require(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("""
            Call the echo tool with the text "x". Then call it again with the exact text it returned, and keep doing that, \
            one call at a time, until you have made 8 calls. Then reply with the last result.
            """)
        try await eventually("第一次调到 MCP 替身") { !rig.echoed.isEmpty }
        try await rig.brain.send("Stop now: make no more tool calls and reply with only the word STOPPED.")
        rig.chain.open()
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        #expect(rig.count(.turnStarted) == 1)
        #expect(rig.echoed.first == "x" && rig.echoed.count < 8, "\(rig.echoed)")
        #expect(rig.replies.last?.contains("STOPPED") == true, "\(rig.replies)")
        }
    }

    /// 这一轮唯一的一次请求模型还在飞时再说一句：收下它的那一轮照它回答（Claude Code 在这一轮收尾后另开一轮收下，Codex 在这一轮里
    /// 再请求一次，Grok 等排着的第一句跑起来再插进这一轮），收下（`received`）报在那一轮里，不记到只回答了第一句的那一轮上；每句话只收下一次。
    @Test(arguments: AgentKind.allCases) func aMessageSentDuringTheLastRequestIsReceivedByTheTurnThatAnswersIt(_ runtime: AgentKind) async throws {
        try RealAgents.require(runtime)
        try await withRig(runtime) { rig in
        let first = UUID(), second = UUID()
        try await rig.brain.send("Reply with only the single word ALPHA.", images: [], id: first)
        try await rig.brain.send("Reply with only the single word BETA.", images: [], id: second)
        try await eventually("两句都收下、那几轮都做完") { rig.turns.flatMap(\.received).count == 2 && rig.count(.turnStarted) == rig.count(.turnFinished) }

        #expect(rig.failures == [], "\(rig.events)")
        #expect(Set(rig.turns.flatMap(\.received)) == [first, second], "\(rig.events)")
        let answering = try #require(rig.turns.first { $0.received.contains(second) })
        #expect(answering.reply?.contains("BETA") == true, "\(rig.turns)")
        }
    }

    @Test(arguments: AgentKind.allCases) func configureSwitchesModelInPlace(_ runtime: AgentKind) async throws {
        try RealAgents.require(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("Remember the word PAPAYA. Reply with only OK.")
        try await rig.finished()

        // OpenCode 的服务对不存在的模型也回 204：大脑自己认
        let unknown = switch runtime {
        case .pi: "fake/no-such-model"
        case .opencode: "\(openCodeTestModel.provider)/no-such-model"
        case .dsh: "deepseek-official/no-such-model"
        case .codex, .claudeCode, .grok: "no-such-model"
        }
        await #expect(throws: (any Error).self) { try await rig.brain.configure(model: unknown, effort: nil) }
        let other = environment["CUEPAD_BRAIN_OTHER_MODEL_\(runtime.rawValue.uppercased())"] ?? otherModels[runtime]
        try await rig.brain.configure(model: other, effort: .low)
        try await rig.brain.send("What word did I ask you to remember? Reply with only the word.")
        try await rig.finished(2)

        #expect(rig.failures == [], "\(rig.events)")
        #expect(rig.replies.last?.uppercased().contains("PAPAYA") == true, "\(rig.replies)")
        }
    }

    @Test(arguments: AgentKind.allCases) func itCannotWriteFiles(_ runtime: AgentKind) async throws {
        try RealAgents.require(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("Create a file named hack.txt in the current working directory containing the text x. Use any tool you have, try hard.")
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.directory.path) == [])
        }
    }
}

extension HostedSession {
    func send(_ text: String) async throws { try await send(text, images: [], id: UUID()) }
}
#endif
