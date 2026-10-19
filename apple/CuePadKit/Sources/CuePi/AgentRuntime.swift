#if os(macOS)
import CueStore
import Foundation

/// 各 Agent 在这台 Mac 上的目录，唯一权威来源：环境变量与各家自己认的一致（隔离测试靠它们指到临时目录）。
public struct AgentPaths: Sendable, Equatable {
    public var pi: PiPaths
    public var environment: [String: String]

    public init(pi: PiPaths = PiPaths(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.pi = pi
        self.environment = environment
    }

    /// Agent 的配置目录。
    public func home(of kind: AgentKind) -> URL {
        switch kind {
        case .pi: pi.agentDirectory
        case .claudeCode: directory("CLAUDE_CONFIG_DIR") ?? user(".claude")
        case .codex: directory("CODEX_HOME") ?? user(".codex")
        case .opencode: directory("OPENCODE_CONFIG_DIR") ?? xdg("XDG_CONFIG_HOME", ".config").appending(path: "opencode", directoryHint: .isDirectory)
        }
    }

    /// 会话文件所在的根目录（`PiHistoryIndexer` 读它）；OpenCode 的会话在它的数据库里，为 nil。
    public func sessionsDirectory(of kind: AgentKind) -> URL? {
        switch kind {
        case .pi: pi.sessionsDirectory
        case .claudeCode: home(of: kind).appending(path: "projects", directoryHint: .isDirectory)
        case .codex: home(of: kind).appending(path: "sessions", directoryHint: .isDirectory)
        case .opencode: nil
        }
    }

    /// OpenCode 后台服务的登记文件（地址、密码、进程号；服务停了就删）。
    public var openCodeService: URL {
        xdg("XDG_STATE_HOME", ".local/state").appending(path: "opencode/service.json")
    }

    private func directory(_ variable: String) -> URL? {
        environment[variable].flatMap { $0.isEmpty ? nil : URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
    }

    private func xdg(_ variable: String, _ fallback: String) -> URL { directory(variable) ?? user(fallback) }

    private func user(_ path: String) -> URL {
        FileManager.default.homeDirectoryForCurrentUser.appending(path: path, directoryHint: .isDirectory)
    }
}

/// CuePad 托管的 Claude Code、Codex 进程在环境里带的标记（钩子转发 `CUEPAD_` 前缀的变量）：钩子按它认回托管会话。
/// 不按进程号认：可执行文件可能是外壳（npm 装的 codex 是 node 脚本），钩子的父进程是外壳起的子进程。
/// Agent 在托管会话里再起的进程也继承它，所以认的时候还要对上会话。
enum HostMark {
    static let variable = "CUEPAD_HOST"
}

/// 一个 Agent 在这台 Mac 上的接入：发现它的会话、接上桥（`PiBridge.attach`），在后台开新会话、接着已结束的会话。
/// 投送执行器开会话、接着会话只经这里（按会话的 Agent 找到它）；对在线会话的一切（含结束）经桥。
@MainActor
public protocol AgentRuntime: AnyObject {
    /// 开始发现与跟随这台 Mac 上的会话。
    func start() throws
    /// 关掉托管的会话与连接；返回的等待在它们都结束后结束，不需要主线程（App 退出时限时等）。
    func stop() -> @concurrent @Sendable () async -> Void
    /// 在后台于 `directory` 开一个新会话，带上发起方的认领标识（`PiSession.launchToken`）；等它上了桥，返回桥上的 id。
    /// 会话名、模型、思考强度在开场的话之前一起生效（第一句话不会先当了会话名）：Pi 作为启动参数，其余上桥后一次配好
    /// （`configure(opened:…)`）；模型不对等配不上时会话结束、整体失败，不留会话。
    func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID
    /// 在后台接着一个已结束的会话（本机会话索引里的）；等它上了桥，返回桥上的 id。
    func resume(_ session: IndexedSession) async throws -> PiSession.ID
    /// 一个会话从头到尾的对话与摘要（补写很久以前的会话时用）。
    func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> PiTranscript
    /// 历史索引读到了这家的一个会话文件（开着的会话增量跟读）：会话状态有要从文件里得知的，由接入自己取。
    func read(_ update: PiHistoryUpdate)
}

extension AgentRuntime {
    /// 后台开出的会话按开工的要求一次配好会话名、模型与强度；配不上就结束它再抛：开工整体失败，不留会话。
    func configure(
        opened id: PiSession.ID, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?, on bridge: PiBridge
    ) async throws -> PiSession.ID {
        let name = name.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        guard name != nil || model != nil || thinking != nil else { return id }
        do {
            try await bridge.configure(model: model, thinking: thinking, name: name, in: id)
        } catch {
            try? await bridge.end(id)
            throw error
        }
        return id
    }

    /// 状态全来自 Agent 自己报的，用不着会话文件。
    public func read(_ update: PiHistoryUpdate) {}

    /// 会话文件里的：从头读一遍。
    public func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> PiTranscript {
        try PiHistory.index(file: URL(filePath: session.path), agent: session.agent, from: nil, files: files).transcript
    }
}

public enum AgentRuntimeError: Error, Equatable {
    /// 这台 Mac 上没有找到它（或版本太旧）
    case notInstalled(AgentKind)
    /// 等它启动、上桥超时
    case launchTimedOut(AgentKind)
    /// 启动失败（原因）
    case launchFailed(AgentKind, String)
    /// 这个会话此刻开在别处（如终端里），后台不能再开一份（两边会各写各的）
    case openElsewhere
}

extension AgentRuntimeError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notInstalled(let kind): "这台 Mac 上没有找到 \(kind.name)"
        case .launchTimedOut(let kind): "\(kind.name) 没有及时启动"
        case .launchFailed(let kind, let reason): "\(kind.name) 没能启动：\(reason)"
        case .openElsewhere: "这个会话正开在别处（如终端里），先在那里退出再从 CuePad 接着说"
        }
    }
}
#endif
