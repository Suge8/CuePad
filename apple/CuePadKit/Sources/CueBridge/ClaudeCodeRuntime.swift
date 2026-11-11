#if os(macOS)
import CueStore
import Foundation

/// 接着会话时先取会话索引里记下的名字与首条消息（`remembered`，不在这里读会话文件）。
/// 托管会话的让出与空闲退出由桥决定（`Bridge` 的托管会话一节）。
@MainActor
public final class ClaudeCodeRuntime: AgentRuntime {
    private let bridge: Bridge
    private let paths: AgentPaths
    private let claude: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    private let store: CueStore
    private let hosted: HostedProcesses
    private let timing: Timing

    public init(
        bridge: Bridge, paths: AgentPaths, store: CueStore, claude: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system }, timing: Timing = .system
    ) {
        self.timing = timing
        self.claude = claude
        self.bridge = bridge
        hosted = HostedProcesses(bridge: bridge, timing: timing)
        self.paths = paths
        self.locate = locate
        self.store = store
    }

    private func checkpoint(of sessionID: String) async -> HistoryCheckpoint? {
        guard let data = try? await store.checkpoint(of: sessionID) else { return nil }
        return try? JSONDecoder().decode(HistoryCheckpoint.self, from: data)
    }

    private func remembered(_ sessionID: String) async -> (name: String?, firstMessage: String?)? {
        await checkpoint(of: sessionID).map { ($0.name, $0.firstMessage) }
    }

    private var home: URL { paths.home(of: .claudeCode) }

    public func start() throws { hosted.start() }

    public func stop() -> @concurrent @Sendable () async -> Void { hosted.stop() }

    public func open(
        in directory: URL, launchToken: String, name: String?, model: ModelKey?, thinking: ThinkingLevel?
    ) async throws -> Session.ID {
        let sessionID = UUID().uuidString.lowercased()
        let id = try await launch(
            sessionID: sessionID, arguments: ["--session-id", sessionID], in: directory, launchToken: launchToken, admission: try hosted.admission())
        return try await configure(opened: id, name: name, model: model, thinking: thinking, on: bridge)
    }

    public func resume(_ session: IndexedSession) async throws -> Session.ID {
        if let live = bridge.sessions.first(where: { $0.agent == .claudeCode && $0.sessionID == session.id }) { return live.id }
        return try await hosted.resume(session.id) { [self] admission in
            // 终端里开着它时两个进程会同写一个会话文件：问 Claude Code 自己
            if try await running().contains(where: { $0.sessionID == session.id }) { throw AgentRuntimeError.openElsewhere }
            let directory = URL(filePath: session.cwd, directoryHint: .isDirectory)
            // Claude Code 接着会话时用配置里的模型，不记得这个会话里换过的：带上 CuePad 记下的
            let model = try? await store.lastModel(ofSession: session.id)
            return try await launch(
                sessionID: session.id, arguments: ["--resume", session.id] + (model.map { ["--model", $0.id] } ?? []), model: model,
                in: directory, launchToken: nil, known: await remembered(session.id), admission: admission)
        }
    }

    /// 不自己补 `CLAUDE_CONFIG_DIR`：设了它 Claude Code 就到那个目录里找 `.claude.json`，与没设时的 `~/.claude.json` 不是一份。
    private func executable() async throws -> (url: URL, environment: [String: String]) {
        guard let claude = await claude() else { throw AgentRuntimeError.notInstalled(.claudeCode) }
        let locator = await locate()
        return (claude, locator.environment(launching: claude, overrides: paths.environment))
    }

    /// 没连上就抛错：进程先退出、握手超时，或调用方取消（投送到了截止时刻）。没连上的都收掉自己起的进程（只收它：
    /// 按会话收会收到别人的），不留一个不在桥上的进程占着这个会话（之后接着它时被当成在别处开着，或再起一个同写会话文件）。
    private func launch(
        sessionID: String, arguments: [String], model: ModelKey? = nil, in directory: URL, launchToken: String?,
        known: (name: String?, firstMessage: String?)? = nil, admission: HostedProcesses.Admission
    ) async throws -> Session.ID {
        let claude = try await executable()
        let session = ClaudeHostedSession(bridge: bridge, processes: hosted, timing: timing)
        // 交给会话的附件在工作目录外（`AttachmentFiles.directory`）：读它不用再问
        let process = try await session.host(
            executable: claude.url, arguments: arguments + ["--add-dir", store.files.directory.path(percentEncoded: false)], directory: directory,
            environment: claude.environment)
        try await hosted.admit(process, for: sessionID, admission)
        let cwd = URL(filePath: ClaudeCode.realPath(directory), directoryHint: .isDirectory)
        do {
            return try await session.connect(
                sessionID: sessionID, cwd: cwd, sessionFile: ClaudeCode.sessionFile(home: home, cwd: cwd, sessionID: sessionID), model: model, launchToken: launchToken,
                known: known).id
        } catch BridgeError.sessionEnded {
            let reason = await process.exited()
            throw ClaudeCodeError.exited(reason)
        } catch {
            await process.stop()
            if error as? BridgeError == .ackTimeout { throw AgentRuntimeError.launchTimedOut(.claudeCode) }
            throw error
        }
    }

    private struct Running: Decodable {
        var sessionID: String
        enum CodingKeys: String, CodingKey { case sessionID = "sessionId" }
    }

    private func running() async throws -> [Running] {
        let claude = try await executable()
        guard let result = await ChildProcess.run(claude.url, ["agents", "--json"], environment: claude.environment, timeout: AgentTimeouts.list, timing: timing),
              result.status == 0 else {
            throw ClaudeCodeError.listingFailed
        }
        return try JSONDecoder().decode([Running].self, from: Data(result.output.utf8))
    }
}

public enum ClaudeCodeError: Error, Equatable, ShownError {
    /// 附它的退出原因；`stop()` 让它退的没有
    case exited(ShownText?)
    case listingFailed

    public var shown: String.LocalizationValue {
        switch self {
        case .exited(let reason): reason.map { "在后台启动的 Claude Code 退出了：\($0.embedded)" } ?? "在后台启动的 Claude Code 没连上就退出了"
        case .listingFailed: "没能问到 Claude Code 此刻在跑哪些会话"
        }
    }
}
#endif
