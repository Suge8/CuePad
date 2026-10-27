#if os(macOS)
import CueStore
import Foundation

/// 在哪里找 Agent 的可执行文件、给 CuePad 起的子进程什么环境：唯一的一处。挑哪一个只由检测定（`AgentIntegration.status(of:)`，
/// 结果是 `AgentStatus.executable`），各家的接入、Cue 的大脑、问模型都用检测挑中的那个，不在这里另挑。
/// GUI 应用的 PATH 很短，所以除了 PATH 还查用户登录 shell 的 PATH 与各家安装脚本的默认位置。
public struct ExecutableLocator: Sendable, Equatable {
    public var searchDirectories: [URL]

    public init(searchDirectories: [URL]) {
        var unique: [URL] = []
        for directory in searchDirectories where !directory.path.isEmpty && !unique.contains(directory) { unique.append(directory) }
        self.searchDirectories = unique
    }

    /// 本进程的 PATH 加常见安装目录（不问登录 shell）。
    public static var standard: ExecutableLocator { ExecutableLocator(shellPath: ProcessInfo.processInfo.environment["PATH"]) }

    /// 这台 Mac 上的：用户登录 shell 的 PATH 在前（Agent 的 bash 看到的是它），再是 `standard`。登录 shell 整个进程只问一次
    /// （慢，至多 5 秒；并发的调用共用这一次），问不到就是 `standard`。生产代码都用它，测试给自己的目录。
    public static var system: ExecutableLocator {
        get async { await resolving.value }
    }

    private static let resolving = Task {
        let login = await loginShellPath()
        return ExecutableLocator(shellPath: [login, ProcessInfo.processInfo.environment["PATH"]].compactMap { $0 }.joined(separator: ":"))
    }

    private init(shellPath: String?) {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = (shellPath ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        // 先找到的先问版本：`.local/bin` 排在 Homebrew 之前，包管理器与 OpenCode 的在后
        let homes = Self.homeDirectories(home)
        self.init(searchDirectories: path + homes.prefix(1) + [URL(filePath: "/opt/homebrew/bin"), URL(filePath: "/usr/local/bin")] + homes.dropFirst())
    }

    /// 只看装在 `home` 里的（官方脚本与包管理器的缺省位置）：隔离运行时把一个空目录当家目录，像一台什么都没装的 Mac。
    public init(home: URL) {
        self.init(searchDirectories: Self.homeDirectories(home))
    }

    /// 家目录里各家安装脚本与包管理器的缺省位置：Claude Code、Codex、Pi 的脚本装进 `.local/bin`，OpenCode 的装进 `.opencode/bin`。
    private static func homeDirectories(_ home: URL) -> [URL] {
        [".local/bin", ".bun/bin", ".npm-global/bin", ".opencode/bin"].map { home.appending(path: $0, directoryHint: .isDirectory) }
    }

    /// 搜索目录里所有叫 `command` 的可执行文件，按目录先后。
    public func candidates(_ command: String) -> [URL] {
        searchDirectories.map { $0.appending(path: command) }.filter { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// 这组目录再保底 /usr/bin 与 /bin，写成 PATH。
    public var path: String { Self.join(searchDirectories) }

    /// 起 `executable` 用的完整环境：CuePad 自己的环境，盖上 `overrides`，去掉各家的会话 id（`AgentKind.sessionVariable`）；
    /// PATH 是可执行文件所在目录（`pi` 是 node 脚本，node 多半与它装在一起）、搜索目录、原有的 PATH（`overrides` 里给了就用它的），
    /// 再保底 /usr/bin 与 /bin。CuePad 在某个 Agent 的命令里被启动时，那个会话的 id 会一路传给开出的会话，`cuepad show` 就发错了地方
    /// （`overrides` 常是一份完整的进程环境，`AgentPaths.environment`，所以在合并之后去掉）。
    public func environment(launching executable: URL, overrides: [String: String] = [:]) -> [String: String] {
        let sessions = Set(AgentKind.allCases.map(\.sessionVariable))
        var environment = ProcessInfo.processInfo.environment.merging(overrides) { $1 }.filter { !sessions.contains($0.key) }
        let inherited = (environment["PATH"] ?? "").split(separator: ":").map { URL(filePath: String($0), directoryHint: .isDirectory) }
        environment["PATH"] = Self.join([executable.deletingLastPathComponent()] + searchDirectories + inherited)
        return environment
    }

    private static func join(_ directories: [URL]) -> String {
        ExecutableLocator(searchDirectories: directories + [URL(filePath: "/usr/bin"), URL(filePath: "/bin")]).searchDirectories.map(\.path)
            .joined(separator: ":")
    }

    /// 用户登录 shell 此刻的 PATH（交互式启动才会读 .zshrc）；`AgentTimeouts.shell` 没结果就放弃。
    public static func loginShellPath(timing: Timing = .system) async -> String? {
        let marker = "__CUEPAD_PATH__"
        let shell = URL(filePath: ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh")
        guard let result = await ChildProcess.run(shell, ["-ilc", "printf '\\n\(marker)%s\\n' \"$PATH\""], timeout: AgentTimeouts.shell, timing: timing) else { return nil }
        return result.output.split(separator: "\n").last { $0.hasPrefix(marker) }.map { String($0.dropFirst(marker.count)) }
    }
}
#endif
