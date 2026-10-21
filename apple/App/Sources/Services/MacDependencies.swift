#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation

/// macOS 专属依赖；`live` 是生产装配，测试换成隔离目录、内存热键、记录型接入与私有剪贴板。
struct MacDependencies {
    var pi: PiBridge
    var hotkeys: any HotkeyBackend
    var paths: AgentPaths
    /// 各家的接入状态（检测出的可执行文件也在里面：各家的接入、Cue 的大脑都从这里取）。
    var agents: AgentIntegrations
    var terminal: PiTerminalJumper
    var hostID: String
    /// 项目工作区的根目录（`Workspaces`）：隔离运行与测试放进隔离目录。
    var workspaces: Workspaces
    /// 系统睡眠与唤醒通知所在的通知中心（生产是 NSWorkspace 的）。
    var wakeNotifications: NotificationCenter
    /// 资料库里随时间变的读与在线记录续期用的时钟（`CueStore.timing`）；测试换成手动推进的。
    var timing: Timing = .system
    /// 命令行工具 `cuepad` 的链接（设置里的开关；Agent 的技能与钩子写的是 App 里那份的绝对路径，不依赖它）。
    var commandLineTool: CommandLineToolInstaller
    /// 自动更新器；隔离模式与测试为 nil。
    var updater: (any AppUpdater)?
    /// Agent 钩子转发到 CuePad 的监听端（Claude Code、Codex 的接入用它）。
    var hooks: AgentHookServer
    /// 各 Agent 的接入：发现会话、后台开新会话与接着已结束的会话、结束会话。OpenCode 的会话索引由它的接入直接写进资料库，
    /// 所以等资料库打开后再建（参数就是它）。
    var runtimes: @MainActor (CueStore) -> [AgentKind: any AgentRuntime]
    var pasteboard: NSPasteboard
    var cue: CueDependencies

    /// 自动更新随正式位置启用；隔离模式（开发与验收）不去读真实的更新源与偏好。
    static func live(location: LibraryLocation, alerts: AlertCenter) -> MacDependencies {
        let environment = ProcessInfo.processInfo.environment
        let sockets = AgentHookEnvelope.socketDirectory(environment: environment, isolatedLibrary: location.isIsolated ? location.directory : nil)
        // 隔离运行另起的连接目录也交给 CuePad 起的每个子进程（托管的 Agent 的钩子、Cue 的大脑），它们才连回这个 App 而不是正式版
        if location.isIsolated { setenv("CUEPAD_PI_SOCKET_DIR", sockets.path, 1) }
        let agentHome = location.isIsolated ? DebugHooks.agentHome : nil
        let paths = AgentPaths(pi: PiPaths(socketDirectory: sockets), environment: agentHome.map { home in
            environment.merging(["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
        } ?? environment)
        let pi = PiBridge(socketDirectory: paths.pi.socketDirectory)
        let hooks = AgentHookServer(path: paths.pi.hookSocket)
        // 隔离运行（开发构建）不碰真实的 `~/.local/bin`：链接放进资料库目录，除非指定了 Pi 目录与链接目录（`PiPaths.isExplicit`）
        let commandLineTool = location.isIsolated && !paths.pi.isExplicit
            ? CommandLineToolInstaller(linkDirectory: location.directory.appending(path: "bin", directoryHint: .isDirectory))
            : CommandLineToolInstaller(linkDirectory: paths.pi.binDirectory)
        let agents = AgentIntegrations(AgentIntegration(
            paths: paths,
            locate: { @Sendable in
                if let agentHome { return ExecutableLocator(searchDirectories: [agentHome.appending(path: ".local/bin")]) }
                return await .system
            },
            cuepad: commandLineTool.helper, isolated: location.isIsolated))
        let hostID = (location.isIsolated ? DebugHooks.hostID : nil) ?? HostIdentity.current()
        return MacDependencies(
            pi: pi,
            hotkeys: CarbonHotkeyBackend(),
            paths: paths,
            agents: agents,
            terminal: PiTerminalJumper(),
            hostID: hostID,
            workspaces: Workspaces.resolve(isolatedLibrary: location.isIsolated ? location.directory : nil),
            wakeNotifications: NSWorkspace.shared.notificationCenter,
            commandLineTool: commandLineTool,
            updater: location.isIsolated ? DebugHooks.updater : SparkleUpdater(),
            hooks: hooks,
            runtimes: { store in [
                .pi: PiRuntime(bridge: pi, paths: paths.pi, pi: { await agents.executable(.pi) }),
                .claudeCode: ClaudeCodeRuntime(bridge: pi, paths: paths, hooks: hooks, store: store, claude: { await agents.executable(.claudeCode) }),
                .codex: CodexRuntime(bridge: pi, paths: paths, hooks: hooks, codex: { await agents.executable(.codex) }),
                .opencode: OpenCodeRuntime(
                    bridge: pi, paths: paths, store: store, hostID: hostID, opencode: { await agents.executable(.opencode) },
                    transcriptWindow: PiHistoryPersistence.transcriptWindow),
            ] },
            pasteboard: .general,
            cue: CueDependencies(
                launch: { [brain = DebugHooks.cueBrain] runtime, store in
                    let executable = if let brain { brain } else { await agents.executable(runtime) }
                    return try await CueLaunch.local(executable: executable, store: store, host: hostID)
                },
                helper: commandLineTool.helper,
                notifier: alerts))
    }
}
#endif
