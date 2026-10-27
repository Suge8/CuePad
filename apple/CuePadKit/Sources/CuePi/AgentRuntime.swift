#if os(macOS)
import CueStore
import Foundation

/// 各 Agent 在这台 Mac 上的目录，唯一权威来源（Pi 与桥的在 `pi`）：环境变量与各家自己认的一致（隔离测试靠它们指到临时目录）。
public struct AgentPaths: Sendable, Equatable {
    public var pi: PiPaths
    public var environment: [String: String]

    public init(pi: PiPaths = PiPaths(), environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.pi = pi
        self.environment = environment
    }

    public func home(of kind: AgentKind) -> URL { kind.facts.home(self) }

    /// 几家共读的目录（`~/.agents`，`CUEPAD_AGENTS_DIR` 换走）：全局技能 `skills`、全局说明 `AGENTS.md`，CuePad 的技能也写在这里。
    /// 环境变量是 CuePad 自己的（各家都按家目录读它）：隔离实例与测试经它换到临时目录。
    public var agentsDirectory: URL { directory("CUEPAD_AGENTS_DIR") ?? user(".agents") }

    /// 家目录：环境里的 `HOME`（换了家目录的隔离实例），没有时是系统的。
    public var userHome: URL { directory("HOME") ?? FileManager.default.homeDirectoryForCurrentUser }

    /// 会话文件所在的根目录（`PiHistoryIndexer` 读它）；OpenCode 的会话在它的数据库里，为 nil。
    public func sessionsDirectory(of kind: AgentKind) -> URL? { kind.facts.sessionFiles?.directory(self) }

    /// OpenCode 后台服务的登记文件（地址、密码、进程号；服务停了就删）。
    public var openCodeService: URL {
        xdg("XDG_STATE_HOME", ".local/state").appending(path: "opencode/service.json")
    }

    func directory(_ variable: String) -> URL? {
        environment[variable].flatMap { $0.isEmpty ? nil : URL(filePath: ($0 as NSString).expandingTildeInPath, directoryHint: .isDirectory) }
    }

    func xdg(_ variable: String, _ fallback: String) -> URL { directory(variable) ?? user(fallback) }

    func user(_ path: String) -> URL { userHome.appending(path: path, directoryHint: .isDirectory) }
}

extension AgentKind {
    /// 这家在 Mac 上与别家不同的全部事实，唯一按家分派的一处；每家的写在它接入类型的 `+Facts` 文件里。
    public var facts: AgentFacts {
        switch self {
        case .pi: PiRuntime.facts
        case .claudeCode: ClaudeCodeRuntime.facts
        case .codex: CodexRuntime.facts
        case .opencode: OpenCodeRuntime.facts
        }
    }

    public var command: String { facts.command }
}

/// 一家 Agent 在这台 Mac 上与别家不同的事实（跨平台的名字、会话变量、模型提供方、能力在 CueStore 的 `AgentKind`）。
/// 没写的项取多数家的值。
public struct AgentFacts: Sendable {
    /// 可执行文件名（`ExecutableLocator.candidates`）
    public let command: String
    /// 指定它配置目录的环境变量（OpenCode 另认 `XDG_CONFIG_HOME`）；不碰真实世界时没给它就不接入这家（`AgentInstallError.isolated`）。
    public let homeVariable: String
    /// 配置目录（`AgentPaths.home(of:)`）
    let home: @Sendable (AgentPaths) -> URL
    /// CuePad 要求的最低版本：有要求的要报得出够新的版本才算装着（`AgentIntegration.detect`）。
    public var minimumVersion: AgentVersion?
    /// 官方安装命令（取自各家官网的安装页）
    let installScript: String
    /// 自带的升级命令：太旧时用它，不重跑安装命令（`installCommand`）
    var upgradeCommand: String?
    /// 官方安装脚本要这台先有的（检测时查，`AgentStatus.lacking`）
    public var installPrerequisite: InstallPrerequisite?
    /// 命令行登录的参数：打开浏览器，在网页上登录完它自己退出（不要终端）；没有的只能在它的终端界面里登录。
    public var loginArguments: [String]?
    /// 没有可执行文件时，有配置目录（用过它，含它的桌面版）也算装着
    var homeMeansInstalled = true
    /// 会话文件怎么认、在哪（会话不在文件里的为 nil）
    var sessionFiles: SessionFileFormat?
    /// CuePad 写给它的上报通道（钩子配置或桥扩展），`executable` 是检测时挑中的那个；没有为 nil。
    var channel: @Sendable (AgentIntegration, _ executable: URL?) -> (any AgentHookConfig)? = { _, _ in nil }
    /// 托管的会话经上报通道上报：没接入就开不出来（`AgentProbe.unconnected`）
    var hostingNeedsChannel = false
    /// 托管的会话是 CuePad 为它起的进程：歇满 `PiBridge.hostedIdle` 由桥请它退出（`PiBridge.reviewHosted`）；
    /// 不是的自己计时或住在它的服务里。
    var releasesIdleHosted = false
    /// 问出不指定模型时用哪个、能选哪些（`AgentProbe`）：nil 是没登录，没回答抛错。
    let probe: @Sendable (_ executable: URL, AgentProbe) async throws -> MacAgent?
    /// 读几家共读的 `~/.agents/skills`（递归、跟链接）。不读的只读自己目录下一层的 `skills/<名>`：CuePad 的技能链过去，
    /// 它的旧技能目录也只找一层。
    var readsSharedSkills = true
    /// 它自己的技能目录名（在它的配置目录与项目的 `projectFolder` 下，`AgentLibraryPlaces.oldSkills`）
    var skillFolders = ["skills"]
    /// 项目里它的目录（`.claude` 这样）
    let projectFolder: String
    /// 它自己管、CuePad 不碰的技能目录（在它的全局技能目录下）
    var selfManagedSkills: String?
    /// 它自己那份全局说明的文件名（在配置目录下）
    var instructionsFile = "AGENTS.md"
    /// 它的全局说明链到 `~/.agents/AGENTS.md`（`AgentLibraryPlaces.linkedKinds`）
    var linksGlobalInstructions = true
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
    func start() throws
    /// 关掉托管的会话与连接；返回的等待在它们都结束后结束，不需要主线程（App 退出时限时等）。
    func stop() -> @concurrent @Sendable () async -> Void
    /// 托管的会话撑得过 App 重启（退出、更新）：`stop()` 不收掉它们，新起的 App 经桥认回。更新只等撑不过的做完（`UpdateService`）。
    var hostedSessionsOutliveApp: Bool { get }
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
    /// 这家哪些会话归 CuePad 管（与索引同一个范围，App 随接入换）：终端里开的会话在范围里才接上桥，已接上的出了范围就下桥，
    /// 每次换了范围补上此刻在跑的。托管的会话不受它管。启动后、给范围之前一个终端会话都不接。
    func follow(_ scope: PiHistoryScope)
    /// 这家的接入（`AgentIntegration.install`）刚新装或升级成功。
    func integrationInstalled()
    /// 这家的接入刚移除（关掉开关）：收起 CuePad 为它起的东西。
    func integrationRemoved() async
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

    /// 终端里的会话不经接入上报（Pi 经桥扩展，装了才有）或整个接入只在接入期间运行（OpenCode）。
    public func follow(_ scope: PiHistoryScope) {}

    public func integrationInstalled() {}

    public func integrationRemoved() async {}

    /// 会话文件里的：从头读一遍。
    public func transcript(of session: IndexedSession, files: AttachmentFiles) async throws -> PiTranscript {
        try PiHistory.index(file: URL(filePath: session.path), agent: session.agent, from: nil, files: files).transcript
    }
}

public enum AgentRuntimeError: Error, Equatable {
    /// 这台 Mac 上没有找到它（或版本太旧）
    case notInstalled(AgentKind)
    case launchTimedOut(AgentKind)
    case launchFailed(AgentKind, String)
    /// 这个会话此刻开在别处（如终端里），后台不能再开一份（两边会各写各的）
    case openElsewhere
}

extension AgentRuntimeError: ShownError {
    public var shown: String.LocalizationValue {
        switch self {
        case .notInstalled(let kind): "这台 Mac 上没有找到 \(kind.name)"
        case .launchTimedOut(let kind): "\(kind.name) 没有及时启动"
        case .launchFailed(let kind, let reason): "\(kind.name) 没能启动：\(reason)"
        case .openElsewhere: "这个会话正开在别处（如终端里），先在那里退出再从 CuePad 接着说"
        }
    }
}
#endif
