#if os(macOS)
import CueStore
import Foundation
import OSLog

/// CuePad 在后台托管的 Pi：没有终端界面，以 RPC 模式运行（`pi --mode rpc`），状态与消息都走桥。
/// 给已结束的会话发消息时恢复它（`resume`），开新会话（`open`）；托管的进程经环境变量 `CUEPAD_HOSTED` 告诉扩展，
/// 扩展在 hello 里带回（`PiSession.hosted`）。
///
/// - 空闲（这一轮做完、没有等你确认、子代理也歇下）满 `idleLimit` 就退出，会话记录与会话文件都在，下次发消息再恢复；
/// - 用户在别处（自己的终端、herdr）打开了同一个会话（同一会话 id 的另一个进程连上桥）：后台进程让出——空闲就马上退，
///   正在跑一轮就等这一轮做完再退（不丢已做的工作）。退出后让接手的进程重新载入会话（`PiBridge.reload`），
///   它这期间没写过就接上那一轮、不分支，写过就由扩展提示一句；
/// - 退出靠关掉它的标准输入：RPC 模式读到 EOF 后正常收尾（扩展先发 bye）。App 退出时一并关掉（`closeAll`）。
@MainActor
public final class PiHost {
    private static let log = Logger(subsystem: "com.sugeh.cuepad", category: "pi-host")
    private let bridge: PiBridge
    private let paths: PiPaths
    private let idleLimit: Duration
    private let connectTimeout: Duration
    private let endTimeout: Duration
    private let searchPath: [URL]
    private let extraArguments: [String]
    private var processes: [Int32: Hosted] = [:]
    private var watcher: Task<Void, Never>?

    /// 一个托管中的进程：关掉 `stdin` 它就收尾退出。
    private final class Hosted {
        let process: Process
        let stdin: Pipe
        /// 进程退出后结束（可以被多处等）。
        let gone: Task<Void, Never>
        var sessionID: String?
        var busy = false
        /// 有人在别处打开了同一个会话：做完这一轮就退。
        var yielding = false
        var idleTimer: Task<Void, Never>?

        init(process: Process, stdin: Pipe, gone: Task<Void, Never>) {
            self.process = process
            self.stdin = stdin
            self.gone = gone
        }
    }

    /// - Parameter extraArguments: 加在 `pi --mode rpc` 后面的参数（测试用来指定假模型、不联网）。
    public init(
        bridge: PiBridge, paths: PiPaths, idleLimit: Duration = .seconds(30 * 60), connectTimeout: Duration = .seconds(30),
        endTimeout: Duration = .seconds(10), searchPath: [URL] = ExecutableLocator.standard.searchDirectories, extraArguments: [String] = []
    ) {
        self.bridge = bridge
        self.paths = paths
        self.idleLimit = idleLimit
        self.connectTimeout = connectTimeout
        self.endTimeout = endTimeout
        self.searchPath = searchPath
        self.extraArguments = extraArguments
    }

    /// 开始跟着桥上的会话变化管理托管进程（空闲计时、让出）。
    public func start() {
        guard watcher == nil else { return }
        let changes = bridge.changes()
        watcher = Task { [weak self] in
            for await change in changes { self?.handle(change) }
        }
    }

    /// 在后台恢复这个会话文件（于 `directory`），等它连上桥后返回。
    public func resume(sessionFile: URL, in directory: URL, executable: URL) async throws -> PiSession {
        try await launch(executable, ["--session", sessionFile.path], in: directory, environment: [:])
    }

    /// 在后台于 `directory` 开一个新会话，带上发起方的认领标识；等它连上桥后返回。
    public func open(in directory: URL, launchToken: String, executable: URL) async throws -> PiSession {
        try await launch(executable, [], in: directory, environment: ["CUEPAD_LAUNCH_TOKEN": launchToken])
    }

    /// 结束一个在线会话，等它真的退出（已经不在线就什么都不做）：托管的进程关掉标准输入，RPC 模式读到 EOF 就收尾，
    /// 不论这一轮在不在跑；终端里开的会话由扩展走 Pi 的正常退出（终端恢复原样、提示怎么恢复这个会话）。
    /// 没有在 `endTimeout` 内退出抛 `PiHostError.notEnded`。
    public func end(_ id: PiSession.ID) async throws {
        guard let session = bridge.session(id: id) else { return }
        let changes = bridge.changes()  // 先订阅再动手：退出的那一刻不会漏
        if let hosted = processes[session.pid] {
            close(hosted)
        } else {
            try await bridge.end(id)
        }
        let timeout = endTimeout
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                for await change in changes {
                    if case .ended(let ended, _) = change, ended.id == id { return }
                }
                throw CancellationError()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PiHostError.notEnded
            }
            defer { group.cancelAll() }
            try await group.next()
        }
    }

    /// 关掉所有托管进程（App 退出时）：返回的等待在所有进程退出后结束，不需要主线程。
    @discardableResult
    public func closeAll() -> @concurrent @Sendable () async -> Void {
        watcher?.cancel()
        watcher = nil
        let gone = processes.values.map(\.gone)
        for hosted in processes.values { close(hosted) }
        processes = [:]
        return {
            for exit in gone { await exit.value }
        }
    }

    // MARK: 进程

    /// 启动并等它的会话连上桥；进程先退出或超时（这时让它退出）都抛错。
    private func launch(
        _ executable: URL, _ arguments: [String], in directory: URL, environment: [String: String]
    ) async throws -> PiSession {
        let process = Process()
        let stdin = Pipe()
        process.executableURL = executable
        process.arguments = ["--mode", "rpc"] + arguments + extraArguments
        process.currentDirectoryURL = directory
        process.environment = ProcessInfo.processInfo.environment
            .merging(paths.launchEnvironment) { $1 }
            .merging(environment) { $1 }
            .merging([Self.hostedVariable: "1", "PATH": Self.path(executable, searchPath)]) { $1 }
        process.standardInput = stdin
        // RPC 的事件与回应走桥，不读标准输出；丢到空设备，管道不会写满
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let (exited, exit) = AsyncStream<Void>.makeStream()
        let (terminated, terminate) = AsyncStream<Void>.makeStream()
        process.terminationHandler = { [weak self] ended in
            let pid = ended.processIdentifier
            exit.yield()
            exit.finish()
            terminate.finish()
            Task { @MainActor in self?.exited(pid) }
        }
        let changes = bridge.changes()  // 先订阅再启动：连上的那一刻不会漏
        try process.run()
        let pid = process.processIdentifier
        let hosted = Hosted(process: process, stdin: stdin, gone: Self.watch(terminated))
        processes[pid] = hosted
        let timeout = connectTimeout
        let connecting = Task { try await withThrowingTaskGroup(of: PiSession?.self) { group in
            group.addTask {
                for await change in changes {
                    if case .appeared(let session) = change, session.pid == pid { return session }
                }
                return nil
            }
            group.addTask {
                for await _ in exited {}
                throw PiHostError.exited
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PiHostError.notConnected
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        } }
        do {
            let value = try await withTaskCancellationHandler { try await connecting.value } onCancel: { connecting.cancel() }
            guard let session = value else { throw CancellationError() }
            return session
        } catch {
            close(hosted)
            throw error
        }
    }

    /// 扩展读这个环境变量判断自己是被 CuePad 托管的。
    static let hostedVariable = "CUEPAD_HOSTED"

    /// `pi` 是 node 脚本：App 的环境里没有用户 shell 的 PATH，按找 Pi 时的同一组目录补上（node 多半与 pi 装在一起）。
    private static func path(_ executable: URL, _ searchPath: [URL]) -> String {
        ([executable.deletingLastPathComponent()] + searchPath).map(\.path).joined(separator: ":")
    }

    /// 进程退出：让出的那个退出后，告诉接手的进程把会话重新载入到最新（让出前做完的那一轮它还没看到）。
    private func exited(_ pid: Int32) {
        guard let hosted = processes.removeValue(forKey: pid) else { return }
        hosted.idleTimer?.cancel()
        guard hosted.yielding, let sessionID = hosted.sessionID,
              let successor = bridge.sessions.first(where: { $0.sessionID == sessionID && $0.pid != pid }) else { return }
        Task {
            do { try await bridge.reload(successor.id) } catch { Self.log.notice("让接手的会话重新载入失败：\(String(describing: error))") }
        }
    }

    /// 不在主线程隔离里建：退出时主线程可能被占住，等进程退出的任务不能排在它后面。
    private nonisolated static func watch(_ terminated: AsyncStream<Void>) -> Task<Void, Never> {
        Task { for await _ in terminated {} }
    }

    private func close(_ hosted: Hosted) {
        hosted.idleTimer?.cancel()
        try? hosted.stdin.fileHandleForWriting.close()
    }

    // MARK: 桥上的变化

    private func handle(_ change: PiSessionChange) {
        switch change {
        case .appeared(let session):
            if let hosted = processes[session.pid] {
                hosted.sessionID = session.sessionID
                update(hosted, busy: session.state.hasPendingWork)
            } else {
                // 同一个会话在别处打开了：托管的那个让出
                for hosted in processes.values where hosted.sessionID == session.sessionID { yield(hosted) }
            }
        case .stateChanged(let session, _):
            if let hosted = processes[session.pid] { update(hosted, busy: session.state.hasPendingWork) }
        case .ended, .infoChanged, .incompatible, .quota:
            break
        }
    }

    private func yield(_ hosted: Hosted) {
        hosted.yielding = true
        if !hosted.busy { close(hosted) }
    }

    private func update(_ hosted: Hosted, busy: Bool) {
        hosted.busy = busy
        hosted.idleTimer?.cancel()
        hosted.idleTimer = nil
        guard !busy else { return }
        if hosted.yielding { return close(hosted) }
        hosted.idleTimer = Task { [weak self, idleLimit] in
            guard (try? await Task.sleep(for: idleLimit)) != nil else { return }
            self?.close(hosted)
        }
    }
}

public enum PiHostError: Error, Equatable {
    /// 后台启动的 Pi 还没连上就退出了
    case exited
    /// 等了很久 Pi 都没连上（已让它退出）
    case notConnected
    /// 请它结束后一直没退出（多半还卡在需要你在终端里处理的地方）
    case notEnded
}

extension PiHostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .exited: "在后台启动的 Pi 没连上就退出了"
        case .notConnected: "在后台启动的 Pi 一直没连上"
        case .notEnded: "会话没有按时结束，可能还在等你在终端里处理"
        }
    }
}
#endif
