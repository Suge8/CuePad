#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 起一个大脑要的本机信息：只找可执行文件，不问登录（登录不了大脑会起不来或一轮出错，由管理器报出）。
nonisolated struct CueLaunch: Equatable, Sendable {
    var executable: URL
    /// 给大脑与 MCP 服务的 PATH：用户登录 shell 的 PATH 加常见安装目录。App 自己的 PATH 很短，运行时起的 node 等靠它找到。
    var path: String
    /// 开会话可选的 Agent 与模型，一项一行（`CuePrompt.system` 的 `agents`）：Pi 设置里的默认模型与用户挑的常用模型（`enabledModels`）。
    var agents: [String]
}

/// 查本机的 Pi、Codex、Claude Code：按登录 shell 的 PATH 与常见目录找可执行文件；`scan()` 再用各家自己的命令问登录了没有
/// （Pi 是 `--list-models` 有没有可用模型，Codex 是 `login status` 的退出码，Claude Code 是 `auth status` 的 `loggedIn`）。
/// 状态命令慢（每条最多等 `timeout`），只在启用、换运行时与大脑起不来时跑；每个班次开始只用 `launch(_:)`。只读，不改任何一家的配置。
nonisolated struct CueRuntimes: Sendable {
    static let order: [CueRuntime] = [.pi, .codex, .claude]
    private static let timeout: Duration = .seconds(15)

    /// Pi 的配置目录（`PiPaths.agentDirectory`）：登录状态与默认模型从这里读。
    var piAgentDirectory: URL
    var shellPath: @Sendable () async -> String? = { await CommandLineToolInstaller.loginShellPath() }

    /// 装了且登录了的，按 `order`。
    @concurrent func scan() async -> [CueRuntime] {
        let directories = await searchDirectories()
        let path = directories.joined(separator: ":")
        let found = Dictionary(uniqueKeysWithValues: Self.order.map { ($0, Self.locate($0, in: directories)) })
        async let pi = loggedIn(found[.pi] ?? nil, ["--list-models"], path: path) { _, output in
            let rows = output.split(separator: "\n")
            return rows.first?.hasPrefix("provider") == true && rows.count > 1  // 没登录时只有一句"No models available…"
        }
        async let codex = loggedIn(found[.codex] ?? nil, ["login", "status"], path: path) { status, _ in status == 0 }
        async let claude = loggedIn(found[.claude] ?? nil, ["auth", "status"], path: path) { _, output in
            (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?["loggedIn"] as? Bool == true
        }
        let ready: [CueRuntime: Bool] = await [.pi: pi, .codex: codex, .claude: claude]
        return Self.order.filter { ready[$0] == true }
    }

    /// 起 `runtime` 的大脑要的可执行文件、PATH 与可选模型；没装为 nil。
    @concurrent func launch(_ runtime: CueRuntime) async -> CueLaunch? {
        let directories = await searchDirectories()
        guard let executable = Self.locate(runtime, in: directories) else { return nil }
        return CueLaunch(executable: executable, path: directories.joined(separator: ":"), agents: agents())
    }

    private func searchDirectories() async -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shell = await shellPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let common = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "/usr/bin", "/bin"]
        var directories: [String] = []
        for directory in shell.split(separator: ":").map(String.init) + common where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        return directories
    }

    private static func locate(_ runtime: CueRuntime, in directories: [String]) -> URL? {
        directories.map { URL(filePath: $0).appending(path: runtime.rawValue) }.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    /// Pi 设置（`settings.json`）里的默认模型在前、标"默认"，再是 `enabledModels`；读不到设置就空着（开工不指定、用默认）。
    private func agents() -> [String] {
        let file = piAgentDirectory.appending(path: "settings.json")
        guard let settings = (try? Data(contentsOf: file)).flatMap({ try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }) else { return [] }
        let preferred = (settings["defaultProvider"] as? String).flatMap { provider in (settings["defaultModel"] as? String).map { "\(provider)/\($0)" } }
        var lines: [String] = []
        if let preferred { lines.append("pi：\(preferred)（默认）") }
        for model in settings["enabledModels"] as? [String] ?? [] where model != preferred {
            lines.append("pi：\(model)")
        }
        return lines
    }

    private func loggedIn(
        _ executable: URL?, _ arguments: [String], path: String, _ check: @Sendable (Int32, String) -> Bool
    ) async -> Bool {
        guard let executable else { return false }
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
            .merging(["PATH": path, "PI_OFFLINE": "1", "PI_CODING_AGENT_DIR": piAgentDirectory.path]) { $1 }
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard let result = await runCapturing(process, timeout: Self.timeout) else { return false }
        return check(result.status, result.output)
    }
}
#endif
