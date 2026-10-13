#if os(macOS)
import CueStore
import Foundation

/// Pi 与 CuePad 桥用到的全部目录，唯一权威来源。
public struct PiPaths: Sendable, Equatable {
    /// Pi 配置根（`PI_CODING_AGENT_DIR`，缺省 `~/.pi/agent`）
    public var agentDirectory: URL
    /// 桥 socket 目录。`sun_path` 上限 104 字节，所以不用 `$TMPDIR`；扩展端用同一缺省值。
    public var socketDirectory: URL

    public var extensionsDirectory: URL { agentDirectory.appending(path: "extensions", directoryHint: .isDirectory) }
    public var sessionsDirectory: URL { agentDirectory.appending(path: "sessions", directoryHint: .isDirectory) }
    /// skill 与扩展同在 Pi 目录下（Pi 自动发现 `<Pi 目录>/skills`）：App 写的文件不进用户自己维护的 `~/.agents/skills`。
    public var skillsDirectory: URL { agentDirectory.appending(path: "skills", directoryHint: .isDirectory) }
    /// Agent 钩子转发到 CuePad 的 socket（`AgentHookServer`），与 Pi 会话的 socket 同目录
    public var hookSocket: URL { AgentHookEnvelope.socketPath(environment: ["CUEPAD_PI_SOCKET_DIR": socketDirectory.path]) }

    public init(
        agentDirectory: URL? = nil,
        socketDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.agentDirectory = agentDirectory ?? Self.defaultAgentDirectory(environment)
        self.socketDirectory = socketDirectory ?? AgentHookEnvelope.socketDirectory(environment: environment)
    }

    /// 由 CuePad 启动的 Pi 要带的环境：连接目录总带（桥在这里找它），Pi 目录不是默认的才带（读写同一份会话与扩展）。
    public var launchEnvironment: [String: String] {
        var environment = ["CUEPAD_PI_SOCKET_DIR": socketDirectory.path]
        if !isDefaultAgentDirectory {
            environment["PI_CODING_AGENT_DIR"] = agentDirectory.path
        }
        return environment
    }

    private var isDefaultAgentDirectory: Bool {
        agentDirectory.standardizedFileURL == Self.defaultAgentDirectory([:]).standardizedFileURL
    }

    private static func defaultAgentDirectory(_ environment: [String: String]) -> URL {
        if let dir = environment["PI_CODING_AGENT_DIR"], !dir.isEmpty {
            return URL(filePath: (dir as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent", directoryHint: .isDirectory)
    }
}
#endif
