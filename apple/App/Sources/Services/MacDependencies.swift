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
    var agents: AgentIntegration
    var terminal: PiTerminalJumper
    var hostID: String
    /// 系统唤醒通知所在的通知中心（生产是 NSWorkspace 的）。
    var wakeNotifications: NotificationCenter
    var commandLineTool: CommandLineToolInstaller
    /// 自动更新器；隔离模式与测试为 nil。
    var updater: SparkleUpdater?
    /// Agent 钩子转发到 CuePad 的监听端（Claude Code、Codex 的接入用它）。
    var hooks: AgentHookServer
    /// 各 Agent 的接入：发现会话、后台开新会话与接着已结束的会话、结束会话。OpenCode 的会话索引由它的接入直接写进资料库，
    /// 所以等资料库打开后再建（参数就是它）。
    var runtimes: @MainActor (CueStore) -> [AgentKind: any AgentRuntime]
    /// 复制的去处。
    var pasteboard: NSPasteboard

    /// 自动更新随正式位置启用；隔离模式（开发与验收）不去读真实的更新源与偏好。
    static func live(location: LibraryLocation) -> MacDependencies {
        let paths = AgentPaths()
        let pi = PiBridge(socketDirectory: paths.pi.socketDirectory)
        let hooks = AgentHookServer(path: paths.pi.hookSocket)
        let commandLineTool = CommandLineToolInstaller()
        let agents = AgentIntegration(paths: paths, cuepad: commandLineTool.helper)
        let hostID = HostIdentity.current()
        return MacDependencies(
            pi: pi,
            hotkeys: CarbonHotkeyBackend(),
            paths: paths,
            agents: agents,
            terminal: PiTerminalJumper(),
            hostID: hostID,
            wakeNotifications: NSWorkspace.shared.notificationCenter,
            commandLineTool: commandLineTool,
            updater: location.isIsolated ? nil : SparkleUpdater(),
            hooks: hooks,
            runtimes: { store in [
                .pi: PiRuntime(host: PiHost(bridge: pi, paths: paths.pi), locate: { await agents.locatePi() }),
                .claudeCode: ClaudeCodeRuntime(bridge: pi, paths: paths, hooks: hooks),
                .codex: CodexRuntime(bridge: pi, paths: paths, hooks: hooks),
                .opencode: OpenCodeRuntime(
                    bridge: pi, paths: paths, store: store, hostID: hostID, transcriptWindow: PiHistoryPersistence.transcriptWindow),
            ] },
            pasteboard: .general)
    }
}
#endif
