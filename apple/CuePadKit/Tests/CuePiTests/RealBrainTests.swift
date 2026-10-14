#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CuePi

/// 端到端：真实的 Pi / Codex / Claude Code 当 Cue 的大脑，用本机用户自己登录的账号与便宜的模型，MCP 是 Fixtures/mcp-echo.mjs 替身。
/// 默认回放录像带，录制与模型、强度的换法见 `RealAgents`（OpenCode 不能当大脑）。
private let environment = ProcessInfo.processInfo.environment
private let runtimes = [AgentKind.pi, .codex, .claudeCode].filter(RealAgents.runs)
/// 连真运行时才看得出的（进程树、各家的历史）：录制时列出、本机装着的几家
private let liveRuntimes = runtimes.filter { RealAgents.mode(of: $0) == .record }
/// Pi 用 openai-codex 的模型：Claude 只走官方 Claude Code，不经 Pi 用 Claude 订阅
private let cheapModels: [AgentKind: String] = [.pi: "openai-codex/gpt-5.6-luna", .codex: "gpt-5.6-luna", .claudeCode: "haiku"]
/// 就地换到的模型：Pi 的上下文窗口与上面的不同，换没换看得出来（Codex 里两个窗口一样，Claude Code 报的是用过的模型里最大的窗口）
private let otherModels: [AgentKind: String] = [.pi: "openai-codex/gpt-6-luna", .codex: "gpt-6-luna", .claudeCode: "sonnet"]
private let echoServer = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/mcp-echo.mjs")
private let home = FileManager.default.homeDirectoryForCurrentUser
/// 缺省 off：最便宜，Codex、Claude Code 还会走夹取
private let effort = environment["CUEPAD_BRAIN_EFFORT"].flatMap(PiThinkingLevel.init(rawValue:)) ?? .off

private func executable(_ name: String) -> URL? {
    let directories = (environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0)) } + [home.appending(path: ".local/bin")]
    return directories.map { $0.appending(path: name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

@MainActor
@Suite(.agentTapes, RealAgents.serialWhenRecording(.pi, .codex, .claudeCode), .timeLimit(.minutes(5)))
struct RealBrainTests {
    /// 一个大脑与它的现场：独立的工作目录（名字里有随机标记，用来在各家的历史里找它）、MCP 替身的调用记录、收到的事件。
    @MainActor
    final class Rig {
        let runtime: AgentKind
        /// 回放时固定（录下的命令行里有它）；连真运行时随机，好在各家的历史里认出这一次
        let marker = AgentTape.current == nil ? "cue-\(UUID().uuidString.prefix(8).lowercased())" : "cue-tape"
        let directory: URL
        let echoLog: URL
        let sessions: URL
        let codename = "ZEBRA-4821"
        let brain: any CueBrain
        private(set) var events: [CueBrainEvent] = []

        init(_ runtime: AgentKind) async throws {
            self.runtime = runtime
            let root = try makeTempDirectory().resolvingSymlinksInPath()
            directory = root.appending(path: marker)
            sessions = root.appending(path: "pi-sessions")
            echoLog = root.appending(path: "echo.log")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = CueBrainConfig(
                runtime: runtime, executable: AgentTape.executable(runtime.command),
                model: environment["CUEPAD_BRAIN_MODEL_\(runtime.rawValue.uppercased())"] ?? cheapModels[runtime], effort: effort,
                systemPrompt: "You are Cue, a test assistant. Your codename is \(codename). Keep answers to one short sentence. When asked to echo something, call the echo tool.",
                workingDirectory: directory,
                mcp: [try #require(executable("node")).path, echoServer.path, marker],
                // Pi 的会话落盘位置指到这里：`--no-session` 生效的话它一直是空的（不去翻用户的 ~/.pi）
                environment: ["MCP_ECHO_LOG": echoLog.path, "PI_CODING_AGENT_SESSION_DIR": sessions.path])
            AgentTape.current?.watch(root)
            brain = try await config.startBrain()
            let events = brain.events
            Task { [weak self] in for await event in events { self?.events.append(event) } }
        }

        func count(_ event: CueBrainEvent) -> Int { events.filter { $0 == event }.count }

        /// 等到第 n 轮做完。
        func finished(_ n: Int = 1) async throws {
            try await eventually("第 \(n) 轮做完", timeout: .seconds(150)) { self.count(.turnFinished) >= n }
        }

        func started(_ n: Int = 1) async throws {
            try await eventually("第 \(n) 轮开始", timeout: .seconds(60)) { self.count(.turnStarted) >= n }
        }

        /// 每轮的回答：做完时还留着的正在说的话
        var replies: [String] {
            var speaking: PiDraft?, replies: [String] = []
            for event in events {
                switch event {
                case .speaking(let draft): speaking = draft
                case .turnFinished:
                    if let text = speaking?.text { replies.append(text) }
                    speaking = nil
                default: break
                }
            }
            return replies
        }
        var failures: [String] { events.compactMap { if case .failed(let text) = $0 { text } else { nil } } }
        var contexts: [(used: Int, window: Int?)] { events.compactMap { if case .context(let used, let window) = $0 { (used, window) } else { nil } } }
        var echoed: [String] { ((try? String(contentsOf: echoLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    }

    /// 起一个大脑跑完测试体，不论成败都等它退出。
    private func withRig(_ runtime: AgentKind, _ body: (Rig) async throws -> Void) async throws {
        let rig = try await Rig(runtime)
        do { try await body(rig) } catch { await rig.brain.stop()(); throw error }
        await rig.brain.stop()()
    }

    /// 发一句话：这一轮开始、报上下文用量（带窗口）、回答、做完；回答出自我们给的系统提示。
    @Test(arguments: runtimes) func aMessageGetsAReplyContextAndAFinishedTurn(_ runtime: AgentKind) async throws {
        AgentTape.use(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("What is your codename? Reply with only the codename.")
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        // 正在说的话的清除可能落在这一轮开始之前（Claude 会），轮次的起止只看别的事件
        let turn = rig.events.filter { if case .speaking = $0 { false } else { true } }
        #expect(turn.first == .turnStarted && turn.last == .turnFinished, "\(rig.events)")
        #expect(rig.replies.count == 1 && rig.replies[0].contains(rig.codename))
        let context = try #require(rig.contexts.last)
        #expect(context.used > 0 && (context.window ?? 0) > context.used)
        }
    }

    /// 带一张图问颜色：图按这家原生的图片输入交给模型，它看得见（红色）。
    @Test(arguments: runtimes) func anImageIsSeen(_ runtime: AgentKind) async throws {
        AgentTape.use(runtime)
        try await withRig(runtime) { rig in
        #expect(rig.brain.seesImages)
        try await rig.brain.send("What color is this image? Reply with only the color name in English.", images: [PiImage(mimeType: "image/png", data: redPNG)])
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        #expect(rig.replies.last?.lowercased().contains("red") == true, "\(rig.replies)")
        }
    }

    /// 一轮进行中再说的话并进这一轮，在下一次请求模型前就起作用，而不是等这一轮做完：一串前后相依的 MCP 调用中途叫停，
    /// 它停在半路、照新的话回答，没有另起一轮。
    @Test(arguments: runtimes) func aMessageDuringATurnJoinsThatTurn(_ runtime: AgentKind) async throws {
        AgentTape.use(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("""
            Call the echo tool with the text "x". Then call it again with the exact text it returned, and keep doing that, \
            one call at a time, until you have made 8 calls. Then reply with the last result.
            """)
        try await eventually("第一次调到 MCP 替身", timeout: .seconds(90)) { !rig.echoed.isEmpty }
        try await rig.brain.send("Stop now: make no more tool calls and reply with only the word STOPPED.")
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        #expect(rig.count(.turnStarted) == 1)
        #expect(rig.echoed.first == "x" && rig.echoed.count < 8, "\(rig.echoed)")
        #expect(rig.replies.last?.contains("STOPPED") == true, "\(rig.replies)")
        }
    }

    /// 就地换模型与强度：同一个进程接着说，前面的话还记得，下一轮用的是新模型（Pi 的上下文窗口跟着变）；
    /// 运行时不认的模型抛错，在用的不变。
    @Test(arguments: runtimes) func configureSwitchesModelInPlace(_ runtime: AgentKind) async throws {
        AgentTape.use(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("Remember the word PAPAYA. Reply with only OK.")
        try await rig.finished()
        let before = try #require(rig.contexts.last?.window)

        let unknown = runtime == .pi ? "openai-codex/no-such-model" : "no-such-model"
        await #expect(throws: (any Error).self) { try await rig.brain.configure(model: unknown, effort: nil) }
        try await rig.brain.configure(model: try #require(otherModels[runtime]), effort: .low)
        try await rig.brain.send("What word did I ask you to remember? Reply with only the word.")
        try await rig.finished(2)

        #expect(rig.failures == [], "\(rig.events)")
        #expect(rig.replies.last?.uppercased().contains("PAPAYA") == true, "\(rig.replies)")
        if runtime == .pi { #expect(rig.contexts.last?.window != before, "\(rig.contexts)") }
        }
    }

    /// 让它写文件：写不出来（没有写工具，或被沙箱拒绝）。
    @Test(arguments: runtimes) func itCannotWriteFiles(_ runtime: AgentKind) async throws {
        AgentTape.use(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("Create a file named hack.txt in the current working directory containing the text x. Use any tool you have, try hard.")
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.directory.path) == [])
        }
    }

    /// 停下这一轮后还能接着说：停下的一轮没有回答，下一句照常回答。
    @Test(arguments: runtimes) func anAbortedTurnHasNoReplyAndTheNextMessageIsAnswered(_ runtime: AgentKind) async throws {
        AgentTape.use(runtime)
        try await withRig(runtime) { rig in
        try await rig.brain.send("Write the numbers from 1 to 400, one per line, in plain text. Do not use any tool.")
        try await rig.started()
        try await rig.brain.abort()
        try await rig.finished()
        #expect(rig.failures == [] && rig.replies == [], "\(rig.events)")

        try await rig.brain.send("Reply with the single word OK.")
        try await rig.finished(2)
        #expect(rig.replies.last?.uppercased().contains("OK") == true)
        }
    }
}

/// 结束后进程连同它起的子进程（MCP 服务等）都退出、各家的历史里没有这次对话：断言的是真进程树与各家真实的历史目录，回放不出来，
/// 只在录制时连真运行时跑。
@MainActor
@Suite(.enabled(if: !liveRuntimes.isEmpty, "只连真运行时跑（看真进程树与各家的历史）：CUEPAD_AGENT_TESTS 列出 pi、codex 或 claude 时开启"), .serialized, .timeLimit(.minutes(5)))
struct RealBrainProcessTests {
    @Test(arguments: liveRuntimes) func stoppingLeavesNoProcessesOrHistory(_ runtime: AgentKind) async throws {
        let rig = try await RealBrainTests.Rig(runtime)
        try await rig.brain.send("Reply with the single word OK.")
        try await rig.finished()

        let tree = try processTree(containing: rig.marker)
        #expect(tree.count >= 2)  // 运行时与 MCP 替身
        await rig.brain.stop()()
        try await eventually("报告退出") { rig.events.last == .exited(nil) }
        let survivors = tree.filter { kill($0, 0) == 0 }
        #expect(survivors == [], "没退出的进程：\(survivors)")

        switch runtime {
        case .pi:
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.sessions.path)) ?? []) == [])
        case .codex:
            #expect(try codexSessions(mentioning: rig.marker) == [])
        case .claudeCode:
            #expect(try claudeTranscripts(for: rig.marker) == [])
        case .opencode:
            Issue.record("OpenCode 不能当大脑")
        }
    }

    /// 大脑进程与它的全部后代：从命令行里带着标记的 MCP 替身往上找到本测试进程的直接子进程（运行时），再取它的整棵子树。
    private func processTree(containing marker: String) throws -> [pid_t] {
        let ps = Process()
        ps.executableURL = URL(filePath: "/bin/ps")
        ps.arguments = ["-A", "-o", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        try ps.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        ps.waitUntilExit()
        let rows = text.split(separator: "\n").compactMap { line -> (pid: pid_t, ppid: pid_t, command: String)? in
            let parts = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3, let pid = pid_t(parts[0]), let ppid = pid_t(parts[1]) else { return nil }
            return (pid, ppid, String(parts[2]))
        }
        let parent = Dictionary(rows.map { ($0.pid, $0.ppid) }, uniquingKeysWith: { a, _ in a })
        var root = try #require(rows.first { $0.command.contains(marker) }).pid
        while let up = parent[root], up != getpid() {
            guard up > 1 else { Issue.record("MCP 替身不在本测试进程之下"); return [] }
            root = up
        }
        var tree = [root]
        var index = 0
        while index < tree.count {
            tree += rows.filter { $0.ppid == tree[index] }.map(\.pid)
            index += 1
        }
        return tree
    }

    /// Codex 的会话文件（只读）里提到这个工作目录的。
    private func codexSessions(mentioning marker: String) throws -> [String] {
        let root = home.appending(path: ".codex/sessions")
        let recent = Date().addingTimeInterval(-600)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey])?.compactMap { $0 as? URL } ?? []
        return files.filter { file in
            guard file.pathExtension == "jsonl", let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  modified > recent, let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
            return text.contains(marker)
        }.map(\.path)
    }

    /// Claude Code 按工作目录存的会话记录（只读）。
    private func claudeTranscripts(for marker: String) throws -> [String] {
        let root = home.appending(path: ".claude/projects")
        let projects = try FileManager.default.contentsOfDirectory(atPath: root.path).filter { $0.contains(marker) }
        return projects.flatMap { project in
            ((try? FileManager.default.contentsOfDirectory(atPath: root.appending(path: project).path)) ?? []).filter { $0.hasSuffix(".jsonl") }
        }
    }
}

private extension CueBrain {
    func send(_ text: String) async throws { try await send(text, images: []) }
}
#endif
