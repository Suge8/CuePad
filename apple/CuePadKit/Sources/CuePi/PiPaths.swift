import Foundation

/// Pi 与 CuePad 桥用到的全部目录，唯一权威来源。
public struct PiPaths: Sendable, Equatable {
    /// Pi 配置根（`PI_CODING_AGENT_DIR`，缺省 `~/.pi/agent`）
    public var agentDirectory: URL
    /// 桥 socket 目录。`sun_path` 上限 104 字节，所以不用 `$TMPDIR`；扩展端用同一缺省值。
    public var socketDirectory: URL

    public var extensionsDirectory: URL { agentDirectory.appending(path: "extensions", directoryHint: .isDirectory) }
    public var sessionsDirectory: URL { agentDirectory.appending(path: "sessions", directoryHint: .isDirectory) }

    public init(
        agentDirectory: URL? = nil,
        socketDirectory: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.agentDirectory = agentDirectory ?? Self.defaultAgentDirectory(environment)
        self.socketDirectory = socketDirectory
            ?? URL(filePath: environment["CUEPAD_PI_SOCKET_DIR"] ?? "/tmp/cuepad-\(getuid())", directoryHint: .isDirectory)
    }

    private static func defaultAgentDirectory(_ environment: [String: String]) -> URL {
        if let dir = environment["PI_CODING_AGENT_DIR"], !dir.isEmpty {
            return URL(filePath: (dir as NSString).expandingTildeInPath, directoryHint: .isDirectory)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".pi/agent", directoryHint: .isDirectory)
    }
}
