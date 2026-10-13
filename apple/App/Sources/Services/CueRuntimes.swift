#if os(macOS)
import CuePi
import CueStore
import Foundation

/// 本机能当 Cue 大脑的一种运行时：装了，也登录了。
nonisolated struct CueRuntimeOption: Equatable, Sendable {
    var runtime: CueRuntime
    var executable: URL
}

/// 一次查看本机运行时的结果。
nonisolated struct CueRuntimeScan: Equatable, Sendable {
    /// 能用的，按启用时的挑选顺序（`CueRuntimes.order`）。
    var available: [CueRuntimeOption]
    /// 给大脑与 MCP 服务的 PATH：用户登录 shell 的 PATH 加常见安装目录。App 自己的 PATH 很短，运行时起的 node 等靠它找到。
    var path: String
    /// 开会话可选的 Agent 与模型，一项一行（`CuePrompt.system` 的 `agents`）：Pi 设置里的默认模型与用户挑的常用模型（`enabledModels`）。
    var agents: [String]

    func option(_ runtime: CueRuntime) -> CueRuntimeOption? { available.first { $0.runtime == runtime } }
}

/// 查本机的 Pi、Codex、Claude Code：按登录 shell 的 PATH 与常见目录找可执行文件，再用各家自己的命令问登录了没有
/// （Pi 是 `--list-models` 有没有可用模型，Codex 是 `login status` 的退出码，Claude Code 是 `auth status` 的 `loggedIn`）。
/// 只读，不改任何一家的配置；每条命令最多等 `timeout`。
nonisolated struct CueRuntimes: Sendable {
    static let order: [CueRuntime] = [.pi, .codex, .claude]
    private static let timeout: Duration = .seconds(15)

    /// Pi 的配置目录（`PiPaths.agentDirectory`）：可用模型与默认模型从这里读。
    var piAgentDirectory: URL
    var shellPath: @Sendable () async -> String? = { await PiIntegration.loginShellPath() }

    @concurrent func scan() async -> CueRuntimeScan {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let shell = await shellPath() ?? ProcessInfo.processInfo.environment["PATH"] ?? ""
        let common = ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "\(home)/.bun/bin", "\(home)/.npm-global/bin", "/usr/bin", "/bin"]
        var directories: [String] = []
        for directory in shell.split(separator: ":").map(String.init) + common where !directory.isEmpty && !directories.contains(directory) {
            directories.append(directory)
        }
        let path = directories.joined(separator: ":")
        let found = Dictionary(uniqueKeysWithValues: Self.order.map { runtime in
            (runtime, directories.map { URL(filePath: $0).appending(path: runtime.rawValue) }.first { FileManager.default.isExecutableFile(atPath: $0.path) })
        })
        async let pi = piLoggedIn(found[.pi] ?? nil, path: path)
        async let codex = loggedIn(found[.codex] ?? nil, ["login", "status"], path: path) { status, _ in status == 0 }
        async let claude = loggedIn(found[.claude] ?? nil, ["auth", "status"], path: path) { _, output in
            (try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any])?["loggedIn"] as? Bool == true
        }
        let (piResult, codexPath, claudePath) = await (pi, codex, claude)
        let ready: [CueRuntime: URL?] = [.pi: piResult, .codex: codexPath, .claude: claudePath]
        let available = Self.order.compactMap { runtime in (ready[runtime] ?? nil).map { CueRuntimeOption(runtime: runtime, executable: $0) } }
        return CueRuntimeScan(available: available, path: path, agents: piResult == nil ? [] : agents())
    }

    /// Pi 列得出可用模型就是登录了（没登录时只有一句"No models available…"）。
    private func piLoggedIn(_ executable: URL?, path: String) async -> URL? {
        guard let executable,
              let output = await run(executable, ["--list-models"], path: path, extra: ["PI_CODING_AGENT_DIR": piAgentDirectory.path])?.output
        else { return nil }
        let rows = output.split(separator: "\n")
        return rows.first?.hasPrefix("provider") == true && rows.count > 1 ? executable : nil
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
    ) async -> URL? {
        guard let executable, let result = await run(executable, arguments, path: path), check(result.status, result.output) else { return nil }
        return executable
    }

    private func run(_ executable: URL, _ arguments: [String], path: String, extra: [String: String] = [:]) async -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment.merging(extra.merging(["PATH": path, "PI_OFFLINE": "1"]) { $1 }) { $1 }
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        return await runCapturing(process, timeout: Self.timeout)
    }
}
#endif
