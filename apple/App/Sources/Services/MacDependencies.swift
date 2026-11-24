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
    var timing: Timing = .system
    var commandLineTool: CommandLineToolInstaller
    var updater: (any AppUpdater)?
    var runtimes: @MainActor (CueStore) -> [AgentKind: any AgentRuntime]
    var pasteboard: NSPasteboard
    var cue: CueDependencies

    static let isolatedHostID = "mac-isolated"

    /// 碰不碰真实世界只看 `LibraryLocation.touchesRealWorld`；
    /// 自动更新只看是不是正式版签名：本机构建装不了 Sparkle 发来的正式版，也不去读真实的更新源与偏好。
    static func live(location: LibraryLocation, alerts: AlertCenter) throws -> MacDependencies {
        let environment = ProcessInfo.processInfo.environment
        let isolated = !location.touchesRealWorld
        AppServices.log.notice("库：\(String(describing: location.origin), privacy: .public)，碰真实世界：\(!isolated, privacy: .public)")
        let sockets = PiPaths.socketDirectory(environment: environment, isolatedLibrary: isolated ? location.directory : nil)
        if isolated { setenv("CUEPAD_PI_SOCKET_DIR", sockets.path, 1) }
        let agentHome = isolated ? DebugHooks.args.agentHome : nil
        let paths = AgentPaths(pi: PiPaths(socketDirectory: sockets), environment: agentHome.map { home in
            environment.merging(["HOME": home.path, "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]) { $1 }
        } ?? environment)
        let timing = Timing.system
        let bridge = Bridge(socketDirectory: paths.pi.socketDirectory, paths: paths, timing: timing)
        let commandLineTool = isolated && !paths.pi.isExplicit
            ? CommandLineToolInstaller(linkDirectory: location.directory.appending(path: "bin", directoryHint: .isDirectory))
            : CommandLineToolInstaller(linkDirectory: paths.pi.binDirectory)
        let agents = AgentIntegrations(AgentIntegration(
            paths: paths,
            locate: { @Sendable in
                if let agentHome { return ExecutableLocator(home: agentHome) }
                return await .system
            },
            isolated: isolated))
        let brief = SessionBrief.text(cuepad: commandLineTool.helper)
        let hostID = isolated ? DebugHooks.args.host.map { "mac-\($0)" } ?? Self.isolatedHostID : HostIdentity.current()
        if isolated { precondition(hostID != HostIdentity.current(), "隔离实例不能用这台 Mac 的标识（-CuePadHost 换个名字）") }
        return MacDependencies(
            bridge: bridge,
            hotkeys: CarbonHotkeyBackend(),
            paths: paths,
            agents: agents,
            hostID: hostID,
            workspaces: try Workspaces.resolve(isolatedLibrary: isolated ? location.directory : nil),
            wakeNotifications: NSWorkspace.shared.notificationCenter,
            timing: timing,
            commandLineTool: commandLineTool,
            updater: AppIdentity.isRelease ? SparkleUpdater() : DebugHooks.updater,
            runtimes: { store in [
                .pi: PiRuntime(bridge: bridge, paths: paths.pi, brief: brief, pi: { await agents.executable(.pi) }),
                .claudeCode: ClaudeCodeRuntime(bridge: bridge, paths: paths, store: store, brief: brief, claude: { await agents.executable(.claudeCode) }),
                .codex: CodexRuntime(bridge: bridge, paths: paths, brief: brief, codex: { await agents.executable(.codex) }),
                .opencode: OpenCodeRuntime(
                    bridge: bridge, paths: paths, store: store, hostID: hostID, brief: brief, opencode: { await agents.executable(.opencode) },
                    transcriptWindow: Chat.transcriptWindow),
                .grok: GrokRuntime(bridge: bridge, paths: paths, brief: brief, grok: { await agents.executable(.grok) }),
                .dsh: DshRuntime(bridge: bridge, paths: paths, brief: brief, dsh: { await agents.executable(.dsh) }),
            ] },
            pasteboard: .general,
            cue: CueDependencies(
                launch: { [brain = DebugHooks.args.driveOpts.cueBrain] runtime, store in
                    let executable = if let brain { brain } else { await agents.executable(runtime) }
                    return try await CueLaunch.local(executable: executable, store: store, host: hostID)
                },
                helper: commandLineTool.helper,
                notifier: alerts))
    }
}
#endif
