#if os(macOS)
import AppKit
import CueBridge
import CueStore
import Foundation

struct MacDependencies {
    var bridge: Bridge
    var hotkeys: any HotkeyBackend
    var paths: AgentPaths
    var agents: AgentIntegrations
    var hostID: String
    var workspaces: Workspaces
    var wakeNotifications: NotificationCenter
    /// `bridge` 必须用同一个钟建（`Bridge.timing`）；测试换成手动推进的。
    var timing: Timing = .system
    /// Agent 的技能写的是 App 里那份的绝对路径，不依赖这个链接。
    var commandLineTool: CommandLineToolInstaller
    var updater: (any AppUpdater)?
    /// OpenCode 的会话索引由它的接入直接写进资料库，所以等资料库打开后再建（参数就是它）。
    var runtimes: @MainActor (CueStore) -> [AgentKind: any AgentRuntime]
    var pasteboard: NSPasteboard
    var cue: CueDependencies

    /// 隔离实例这台 Mac 的标识（没给 `-CuePadHost` 时）：不是任何真实的 Mac，库里记给真实 Mac 的东西在它看来都是别台的。
    static let isolatedHostID = "mac-isolated"

    /// 碰不碰真实世界只看 `LibraryLocation.touchesRealWorld`；
    /// 自动更新只看是不是正式版签名：本机构建装不了 Sparkle 发来的正式版，也不去读真实的更新源与偏好。
    static func live(location: LibraryLocation, alerts: AlertCenter) -> MacDependencies {
        let environment = ProcessInfo.processInfo.environment
        let isolated = !location.touchesRealWorld
        AppServices.log.notice("库：\(String(describing: location.origin), privacy: .public)，碰真实世界：\(!isolated, privacy: .public)")
        let sockets = PiPaths.socketDirectory(environment: environment, isolatedLibrary: isolated ? location.directory : nil)
        // 另起的连接目录也交给 CuePad 起的每个子进程（托管的 Pi、Cue 的大脑），它们才连回这个 App 而不是正式版
        if isolated { setenv("CUEPAD_PI_SOCKET_DIR", sockets.path, 1) }
        let agentHome = isolated ? DebugHooks.agentHome : nil
        let paths = AgentPaths(pi: PiPaths(socketDirectory: sockets), environment: agentHome.map { home in
            environment.merging(["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
        } ?? environment)
        let timing = Timing.system
        let bridge = Bridge(socketDirectory: paths.pi.socketDirectory, timing: timing)
        // 不碰真实世界时不碰真实的 `~/.local/bin`：链接放进资料库目录，除非指定了 Pi 目录与链接目录（`PiPaths.isExplicit`）
        let commandLineTool = isolated && !paths.pi.isExplicit
            ? CommandLineToolInstaller(linkDirectory: location.directory.appending(path: "bin", directoryHint: .isDirectory))
            : CommandLineToolInstaller(linkDirectory: paths.pi.binDirectory)
        let agents = AgentIntegrations(AgentIntegration(
            paths: paths,
            locate: { @Sendable in
                if let agentHome { return ExecutableLocator(home: agentHome) }
                return await .system
            },
            cuepad: commandLineTool.helper, isolated: isolated))
        let hostID = isolated ? DebugHooks.hostID ?? Self.isolatedHostID : HostIdentity.current()
        // 隔离实例用真实库的副本时，副本里记给这台的请求、会话索引（真实 ~/.pi 下的会话文件）、项目文件夹与 Cue 值班都按本机 id 认，
        // 冒充了这台就会在真实目录里恢复、开会话（#34）
        if isolated { precondition(hostID != HostIdentity.current(), "隔离实例不能用这台 Mac 的标识（-CuePadHost 换个名字）") }
        return MacDependencies(
            bridge: bridge,
            hotkeys: CarbonHotkeyBackend(),
            paths: paths,
            agents: agents,
            hostID: hostID,
            workspaces: Workspaces.resolve(isolatedLibrary: isolated ? location.directory : nil),
            wakeNotifications: NSWorkspace.shared.notificationCenter,
            timing: timing,
            commandLineTool: commandLineTool,
            updater: AppIdentity.isRelease ? SparkleUpdater() : DebugHooks.updater,
            runtimes: { store in [
                .pi: PiRuntime(bridge: bridge, paths: paths.pi, pi: { await agents.executable(.pi) }),
                .claudeCode: ClaudeCodeRuntime(bridge: bridge, paths: paths, store: store, claude: { await agents.executable(.claudeCode) }),
                .codex: CodexRuntime(bridge: bridge, paths: paths, codex: { await agents.executable(.codex) }),
                .opencode: OpenCodeRuntime(
                    bridge: bridge, paths: paths, store: store, hostID: hostID, opencode: { await agents.executable(.opencode) },
                    transcriptWindow: Chat.transcriptWindow),
                .grok: GrokRuntime(bridge: bridge, paths: paths, grok: { await agents.executable(.grok) }),
                .dsh: DshRuntime(bridge: bridge, paths: paths, dsh: { await agents.executable(.dsh) }),
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
