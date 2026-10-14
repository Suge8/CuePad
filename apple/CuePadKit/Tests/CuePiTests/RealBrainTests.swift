#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Synchronization
import Testing
@testable import CuePi

/// 端到端：真实的 Pi / Codex / Claude Code 当 Cue 的大脑，用本机用户自己登录的账号与便宜的模型，MCP 是 Fixtures/mcp-echo.mjs 替身。
/// 要花钱，默认不跑：`CUEPAD_BRAIN_TESTS=pi,codex,claude` 开启列出的运行时；模型用 `CUEPAD_BRAIN_MODEL_PI` 等换，强度用 `CUEPAD_BRAIN_EFFORT` 换（缺省 off）。
private let environment = ProcessInfo.processInfo.environment
private let enabledRuntimes: [CueRuntime] = (environment["CUEPAD_BRAIN_TESTS"] ?? "").split(separator: ",").compactMap { CueRuntime(rawValue: String($0)) }
private let cheapModels: [CueRuntime: String] = [.pi: "anthropic/claude-haiku-4-5", .codex: "gpt-5.6-luna", .claude: "haiku"]
private let echoServer = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/mcp-echo.mjs")
private let home = FileManager.default.homeDirectoryForCurrentUser
/// 缺省 off：最便宜，Codex、Claude Code 还会走夹取
private let effort = environment["CUEPAD_BRAIN_EFFORT"].flatMap(PiThinkingLevel.init(rawValue:)) ?? .off

private func executable(_ name: String) -> URL? {
    let directories = (environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0)) } + [home.appending(path: ".local/bin")]
    return directories.map { $0.appending(path: name) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
}

@Suite(.enabled(if: !enabledRuntimes.isEmpty, "要花钱：CUEPAD_BRAIN_TESTS=pi,codex,claude 开启"), .serialized, .timeLimit(.minutes(5)))
struct RealBrainTests {
    /// 一个大脑与它的现场：独立的工作目录（名字里有随机标记，用来在各家的历史里找它）、MCP 替身的调用记录、收到的事件。
    final class Rig: Sendable {
        let runtime: CueRuntime
        let marker = "cue-\(UUID().uuidString.prefix(8).lowercased())"
        let directory: URL
        let echoLog: URL
        let sessions: URL
        let codename = "ZEBRA-\(Int.random(in: 1000...9999))"
        let brain: any CueBrain
        private let received = Mutex<[CueBrainEvent]>([])
        var events: [CueBrainEvent] { received.withLock { $0 } }

        init(_ runtime: CueRuntime) async throws {
            self.runtime = runtime
            let root = try makeTempDirectory().resolvingSymlinksInPath()
            directory = root.appending(path: marker)
            sessions = root.appending(path: "pi-sessions")
            echoLog = root.appending(path: "echo.log")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = CueBrainConfig(
                runtime: runtime, executable: try #require(executable(runtime.rawValue)),
                model: environment["CUEPAD_BRAIN_MODEL_\(runtime.rawValue.uppercased())"] ?? cheapModels[runtime], effort: effort,
                systemPrompt: "You are Cue, a test assistant. Your codename is \(codename). Keep answers to one short sentence. When asked to echo something, call the echo tool.",
                workingDirectory: directory,
                mcp: [try #require(executable("node")).path, echoServer.path, marker],
                // Pi 的会话落盘位置指到这里：`--no-session` 生效的话它一直是空的（不去翻用户的 ~/.pi）
                environment: ["MCP_ECHO_LOG": echoLog.path, "PI_CODING_AGENT_SESSION_DIR": sessions.path])
            brain = try await config.startBrain()
            let events = brain.events
            Task { [weak self] in for await event in events { self?.received.withLock { $0.append(event) } } }
        }

        func count(_ event: CueBrainEvent) -> Int { events.filter { $0 == event }.count }

        /// 等到第 n 轮做完。
        func finished(_ n: Int = 1) async throws {
            try await eventually("第 \(n) 轮做完", timeout: .seconds(150)) { self.count(.turnFinished) >= n }
        }

        func started(_ n: Int = 1) async throws {
            try await eventually("第 \(n) 轮开始", timeout: .seconds(60)) { self.count(.turnStarted) >= n }
        }

        var replies: [String] { events.compactMap { if case .reply(let text) = $0 { text } else { nil } } }
        var failures: [String] { events.compactMap { if case .failed(let text) = $0 { text } else { nil } } }
        var contexts: [(used: Int, window: Int?)] { events.compactMap { if case .context(let used, let window) = $0 { (used, window) } else { nil } } }
        var echoed: [String] { ((try? String(contentsOf: echoLog, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init) }
    }

    /// 起一个大脑跑完测试体，不论成败都等它退出。
    private func withRig(_ runtime: CueRuntime, _ body: (Rig) async throws -> Void) async throws {
        let rig = try await Rig(runtime)
        do { try await body(rig) } catch { await rig.brain.stop(); throw error }
        await rig.brain.stop()
    }

    /// 发一句话：这一轮开始、报上下文用量（带窗口）、回答、做完；回答出自我们给的系统提示。
    @Test(arguments: enabledRuntimes) func aMessageGetsAReplyContextAndAFinishedTurn(_ runtime: CueRuntime) async throws {
        try await withRig(runtime) { rig in
        try await rig.brain.send("What is your codename? Reply with only the codename.")
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        #expect(rig.events.first == .turnStarted && rig.events.last == .turnFinished)
        #expect(rig.replies.count == 1 && rig.replies[0].contains(rig.codename))
        let context = try #require(rig.contexts.last)
        #expect(context.used > 0 && (context.window ?? 0) > context.used)
        }
    }

    /// 一轮进行中再说的话并进这一轮，在下一次请求模型前就起作用，而不是等这一轮做完：一串前后相依的 MCP 调用中途叫停，
    /// 它停在半路、照新的话回答，没有另起一轮。
    @Test(arguments: enabledRuntimes) func aMessageDuringATurnJoinsThatTurn(_ runtime: CueRuntime) async throws {
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

    /// 让它写文件：写不出来（没有写工具，或被沙箱拒绝）。
    @Test(arguments: enabledRuntimes) func itCannotWriteFiles(_ runtime: CueRuntime) async throws {
        try await withRig(runtime) { rig in
        try await rig.brain.send("Create a file named hack.txt in the current working directory containing the text x. Use any tool you have, try hard.")
        try await rig.finished()

        #expect(rig.failures == [], "\(rig.events)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: rig.directory.path) == [])
        }
    }

    /// 停下这一轮后还能接着说；结束后进程连同它起的子进程（MCP 服务等）都退出，各家的历史里没有这次对话。
    @Test(arguments: enabledRuntimes) func abortAndStopLeaveNoProcessesOrHistory(_ runtime: CueRuntime) async throws {
        let rig = try await Rig(runtime)
        try await rig.brain.send("Write the numbers from 1 to 400, one per line, in plain text. Do not use any tool.")
        try await rig.started()
        try await rig.brain.abort()
        try await rig.finished()
        #expect(rig.failures == [] && rig.replies == [], "\(rig.events)")  // 停下的一轮没有回答

        try await rig.brain.send("Reply with the single word OK.")
        try await rig.finished(2)
        #expect(rig.replies.last?.uppercased().contains("OK") == true)

        let tree = try processTree(containing: rig.marker)
        #expect(tree.count >= 2)  // 运行时与 MCP 替身
        await rig.brain.stop()
        try await eventually("报告退出") { rig.events.last == .exited(nil) }
        let survivors = tree.filter { kill($0, 0) == 0 }
        #expect(survivors == [], "没退出的进程：\(survivors)")

        switch runtime {
        case .pi:
            #expect(((try? FileManager.default.contentsOfDirectory(atPath: rig.sessions.path)) ?? []) == [])
        case .codex:
            #expect(try codexSessions(mentioning: rig.marker) == [])
        case .claude:
            #expect(try claudeTranscripts(for: rig.marker) == [])
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
#endif
