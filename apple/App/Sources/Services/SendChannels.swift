#if os(macOS)
import AppKit
import CueDispatch
import CuePi
import CueStore
import Foundation

nonisolated struct PiSessionInfo {
    var target: SendTarget
    var isBusy: Bool
}

/// 发送的落地接缝：真实实现连 Pi 桥、Dispatcher 与系统剪贴板，测试用记录型替身。
@MainActor
protocol SendChannels {
    func piSession(_ id: CuePi.PiSession.ID) -> PiSessionInfo?
    /// Pi 自己的会话 id（手机与同步记录里用的）→ 这台 Mac 上桥连接的会话 id；不在这台 Mac 上则 nil。
    func piSessionID(forSession sessionID: String) -> CuePi.PiSession.ID?
    func send(_ message: PiMessage, to id: CuePi.PiSession.ID) async throws
    func paste(_ text: String, into id: CuePi.PiSession.ID) async throws
    /// 权限与目标检查，不改任何状态；失败时调用方不必动窗口。
    func preflight(_ selector: TargetSelector) async throws
    func dispatch(_ payload: Payload, to selector: TargetSelector, submit: Bool) async throws -> AppInfo
    func copy(_ payload: Payload) throws
    func runningApps() -> [AppInfo]
    func lastFrontmost() -> AppInfo?
}

@MainActor
struct LiveSendChannels: SendChannels {
    let pi: PiBridge
    let apps: WorkspaceApps
    let dispatcher: Dispatcher
    let pasteboard = PasteboardWriter()

    init(pi: PiBridge, bundleID: String) {
        let apps = WorkspaceApps(excludedBundleID: bundleID)
        self.pi = pi
        self.apps = apps
        dispatcher = .live(apps: apps)
    }

    func piSession(_ id: CuePi.PiSession.ID) -> PiSessionInfo? {
        pi.sessions.first { $0.id == id }.map {
            PiSessionInfo(
                target: SendTarget(kind: .piSession, name: $0.cwd.lastPathComponent, ref: $0.sessionID),
                isBusy: $0.state.isBusy)
        }
    }

    func piSessionID(forSession sessionID: String) -> CuePi.PiSession.ID? {
        pi.sessions.first { $0.sessionID == sessionID }?.id
    }

    func send(_ message: PiMessage, to id: CuePi.PiSession.ID) async throws {
        try await pi.send(message, to: id)
    }

    func paste(_ text: String, into id: CuePi.PiSession.ID) async throws {
        try await pi.paste(text, into: id)
    }

    func preflight(_ selector: TargetSelector) async throws {
        guard Accessibility.isTrusted() else { throw DispatchError.accessibilityRequired }
        _ = try await dispatcher.resolve(selector)
    }

    func dispatch(_ payload: Payload, to selector: TargetSelector, submit: Bool) async throws -> AppInfo {
        try await dispatcher.dispatch(payload, to: selector, submit: submit)
    }

    func copy(_ payload: Payload) throws { try pasteboard.write(payload) }
    func runningApps() -> [AppInfo] { apps.runningTargets() }
    func lastFrontmost() -> AppInfo? { apps.lastFrontmost() }
}

extension PiAgentState {
    /// 会话正在处理一轮：此时发消息要么插话要么排队。
    var isBusy: Bool {
        switch self {
        case .thinking, .outputting, .tool, .waitingUser: true
        case .idle, .done, .error: false
        }
    }
}

/// macOS 专属依赖；`live` 是生产装配，测试逐项替换。
struct MacDependencies {
    var pi: PiBridge
    var channels: any SendChannels
    var hotkeys: any HotkeyBackend
    var paths: PiPaths
    var installer: PiExtensionInstaller
    var terminal: PiTerminalJumper
    var isAccessibilityTrusted: @Sendable () -> Bool
    /// 索引落盘的存储；nil 用资料库本身，测试注入失败替身。
    var historyStorage: (any PiIndexStorage)?
    var hostID: String
    /// 系统唤醒通知所在的通知中心（生产是 NSWorkspace 的）。
    var wakeNotifications: NotificationCenter

    @MainActor
    static func live(bundleID: String) -> MacDependencies {
        let paths = PiPaths()
        let pi = PiBridge(socketDirectory: paths.socketDirectory)
        return MacDependencies(
            pi: pi,
            channels: LiveSendChannels(pi: pi, bundleID: bundleID),
            hotkeys: CarbonHotkeyBackend(),
            paths: paths,
            installer: PiExtensionInstaller(paths: paths),
            terminal: PiTerminalJumper(),
            isAccessibilityTrusted: Accessibility.isTrusted,
            historyStorage: nil,
            hostID: HostIdentity.current(),
            wakeNotifications: NSWorkspace.shared.notificationCenter)
    }
}
#endif
