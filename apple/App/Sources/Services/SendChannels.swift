#if os(macOS)
import AppKit
import CuePi
import CueStore
import Foundation

nonisolated struct PiSessionInfo {
    var target: SendTarget
    var isBusy: Bool
}

/// 发送的落地接缝：真实实现连 Pi 桥与系统剪贴板，测试用记录型替身。
@MainActor
protocol SendChannels {
    func piSession(_ id: CuePi.PiSession.ID) -> PiSessionInfo?
    /// Pi 自己的会话 id（手机与同步记录里用的）→ 这台 Mac 上桥连接的会话 id；不在这台 Mac 上则 nil。
    func piSessionID(forSession sessionID: String) -> CuePi.PiSession.ID?
    func send(_ message: PiMessage, to id: CuePi.PiSession.ID) async throws
    func answer(_ answer: PiPromptAnswer, to prompt: String, in id: CuePi.PiSession.ID) async throws
    func configure(model: PiModelRef?, thinking: String?, name: String?, in id: CuePi.PiSession.ID) async throws
    func command(_ line: String, whenBusy: PiQueueMode?, in id: CuePi.PiSession.ID) async throws
    func abort(in id: CuePi.PiSession.ID) async throws
    func copy(_ content: ClipboardContent) throws
}

@MainActor
struct LiveSendChannels: SendChannels {
    let pi: PiBridge

    func piSession(_ id: CuePi.PiSession.ID) -> PiSessionInfo? {
        pi.session(id: id).map {
            PiSessionInfo(
                target: SendTarget(kind: .piSession, name: $0.displayName, ref: $0.sessionID),
                isBusy: $0.state.isBusy)
        }
    }

    func piSessionID(forSession sessionID: String) -> CuePi.PiSession.ID? {
        pi.session(sessionID: sessionID)?.id
    }

    func send(_ message: PiMessage, to id: CuePi.PiSession.ID) async throws {
        try await pi.send(message, to: id)
    }

    func answer(_ answer: PiPromptAnswer, to prompt: String, in id: CuePi.PiSession.ID) async throws {
        try await pi.answer(answer, to: prompt, in: id)
    }

    func configure(model: PiModelRef?, thinking: String?, name: String?, in id: CuePi.PiSession.ID) async throws {
        try await pi.configure(model: model, thinking: thinking, name: name, in: id)
    }

    func command(_ line: String, whenBusy: PiQueueMode?, in id: CuePi.PiSession.ID) async throws {
        try await pi.command(line, whenBusy: whenBusy, in: id)
    }

    func abort(in id: CuePi.PiSession.ID) async throws {
        try await pi.abort(id)
    }

    func copy(_ content: ClipboardContent) throws { try Clipboard.write(content) }
}

extension PiAgentState {
    /// 会话正在处理一轮：此时发消息要么马上说、要么等它做完再说（与手机同一条规则，见 `PiWorkState.isTurnRunning`）。
    var isBusy: Bool { syncRepresentation.state.isTurnRunning }
}

/// macOS 专属依赖；`live` 是生产装配，测试逐项替换。
struct MacDependencies {
    var pi: PiBridge
    var channels: any SendChannels
    var hotkeys: any HotkeyBackend
    var paths: PiPaths
    var installer: PiIntegration
    var terminal: PiTerminalJumper
    var hostID: String
    /// 系统唤醒通知所在的通知中心（生产是 NSWorkspace 的）。
    var wakeNotifications: NotificationCenter
    var commandLineTool: CommandLineToolInstaller
    /// 自动更新器；隔离模式与测试为 nil。
    var updater: SparkleUpdater?
    /// 后台托管 Pi（给已结束的会话发消息、开新会话）。
    var host: any PiHosting
    /// 这台 Mac 上的 Pi 可执行文件；没装为 nil。
    var locatePi: @Sendable () async -> URL?

    /// 自动更新随正式位置启用；隔离模式（开发与验收）不去读真实的更新源与偏好。
    @MainActor
    static func live(location: LibraryLocation) -> MacDependencies {
        let paths = PiPaths()
        let pi = PiBridge(socketDirectory: paths.socketDirectory)
        let commandLineTool = CommandLineToolInstaller()
        let installer = PiIntegration(paths: paths, cuepad: commandLineTool.helper)
        return MacDependencies(
            pi: pi,
            channels: LiveSendChannels(pi: pi),
            hotkeys: CarbonHotkeyBackend(),
            paths: paths,
            installer: installer,
            terminal: PiTerminalJumper(),
            hostID: HostIdentity.current(),
            wakeNotifications: NSWorkspace.shared.notificationCenter,
            commandLineTool: commandLineTool,
            updater: location.isIsolated ? nil : SparkleUpdater(),
            host: PiHost(bridge: pi, paths: paths),
            locatePi: {
                if case .found(let executable, _) = await installer.status().pi { executable } else { nil }
            })
    }
}
#endif
