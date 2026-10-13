#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation

/// macOS 专属依赖；`live` 是生产装配，测试换成隔离目录、内存热键、记录型托管与私有剪贴板。
struct MacDependencies {
    var pi: PiBridge
    var hotkeys: any HotkeyBackend
    var paths: PiPaths
    var installer: PiIntegration
    var terminal: PiTerminalJumper
    var hostID: String
    /// 系统唤醒通知所在的通知中心（生产是 NSWorkspace 的）。
    var wakeNotifications: NotificationCenter
    /// 自动更新器；隔离模式与测试为 nil。
    var updater: SparkleUpdater?
    /// 后台托管 Pi（给已结束的会话发消息、开新会话）。
    var host: any PiHosting
    /// 这台 Mac 上的 Pi 可执行文件；没装为 nil。
    var locatePi: @Sendable () async -> URL?
    /// 复制的去处。
    var pasteboard: NSPasteboard
    var cue: CueDependencies

    /// 自动更新随正式位置启用；隔离模式（开发与验收）不去读真实的更新源与偏好。
    static func live(location: LibraryLocation) -> MacDependencies {
        let paths = PiPaths()
        let pi = PiBridge(socketDirectory: paths.socketDirectory)
        let installer = PiIntegration(paths: paths, helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/cuepad"))
        return MacDependencies(
            pi: pi,
            hotkeys: CarbonHotkeyBackend(),
            paths: paths,
            installer: installer,
            terminal: PiTerminalJumper(),
            hostID: HostIdentity.current(),
            wakeNotifications: NSWorkspace.shared.notificationCenter,
            updater: location.isIsolated ? nil : SparkleUpdater(),
            host: PiHost(bridge: pi, paths: paths),
            locatePi: {
                if case .found(let executable, _) = await installer.status().pi { executable } else { nil }
            },
            pasteboard: .general,
            cue: CueDependencies(
                scan: { [runtimes = CueRuntimes(piAgentDirectory: paths.agentDirectory)] in await runtimes.scan() },
                launch: { [runtimes = CueRuntimes(piAgentDirectory: paths.agentDirectory)] in await runtimes.launch($0) },
                helper: Bundle.main.bundleURL.appending(path: "Contents/Helpers/cuepad"),
                notifier: location.isIsolated ? LoggedCueNotifier() : SystemCueNotifier()))
    }
}
#endif
