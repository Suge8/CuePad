#if os(macOS)
import CueStore
import Darwin
import Foundation
import OSLog

/// CuePad 在后台托管的 Pi：没有终端界面，以 RPC 模式运行（`pi --mode rpc`），状态与消息都走桥。
/// 给已结束的会话发消息时恢复它（`resume`），开新会话（`open`）。
///
/// 托管的进程与终端里开的会话是同一个模型：它自己管生死，CuePad 只是连上去看和发的客户端。
/// - 启动即脱离 App：新会话组、只继承列出的几个文件描述符；标准输入是它自己同时握着两端的管道（RPC 模式读到 EOF 就收尾，
///   这样永远读不到），App 不持有它的任何管道。App 退出、更新、崩溃都不影响它，新起的 App 经桥重新看到它；
/// - 经环境变量 `CUEPAD_HOSTED`（值是空闲多少秒后退出，格式见 README「协议」）告诉扩展：扩展在 hello 里带回（`PiSession.hosted`），
///   空闲（这一轮做完、没有等你确认、子代理也歇下）满时限就自己退出；
/// - 有哪些托管会话只看桥（`hosted` 与 hello 里的 pid），这里不记进程。结束、让出、不兼容退出都是给那个 pid 发 SIGTERM，
///   Pi 收到后优雅收尾（扩展先发 bye）；
/// - 让出：同一会话 id 在别处（自己的终端、herdr）也打开着时，托管的那个空闲就退、正在跑一轮就等做完再退；退出后让接手的进程
///   重新载入会话（`PiBridge.reload`），它这期间没写过就接上那一轮、不分支，写过就由扩展提示一句；
/// - 扩展协议号变了（App 更新后）的托管进程没有终端能 /reload：让它退出，下次发消息用新扩展恢复。
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
    private var watcher: Task<Void, Never>?
    /// 已经发过 SIGTERM 的进程：同一个只发一次（Pi 收尾中再收到一次会跳过收尾直接退出）。随它结束清掉。
    private var stopping: Set<Int32> = []

    /// - Parameter idleLimit: 托管进程空闲多久自己退出（交给扩展计时）。
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

    /// 开始跟着桥上的会话变化做让出与不兼容退出。
    public func start() {
        guard watcher == nil else { return }
        let changes = bridge.changes()
        watcher = Task { [weak self] in
            for await change in changes { self?.handle(change) }
        }
        settle()
    }

    /// 在后台恢复这个会话文件（于 `directory`），等它连上桥后返回。
    public func resume(sessionFile: URL, in directory: URL, executable: URL) async throws -> PiSession {
        try await launch(executable, ["--session", sessionFile.path], in: directory, environment: [:])
    }

    /// 在后台于 `directory` 开一个新会话，带上发起方的认领标识；等它连上桥后返回。会话名、模型与思考强度是 Pi 的启动参数
    /// （`--name`、`--model`、`--thinking`），给了就一起生效；模型不存在或没登录时 Pi 起来就退出，抛 `exited` 并带上 Pi 的原话。
    public func open(
        in directory: URL, launchToken: String, name: String? = nil, model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil,
        executable: URL
    ) async throws -> PiSession {
        var arguments: [String] = []
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { arguments += ["--name", name] }
        if let model { arguments += ["--model", "\(model.provider)/\(model.id)"] }
        if let thinking { arguments += ["--thinking", thinking.rawValue] }
        return try await launch(executable, arguments, in: directory, environment: ["CUEPAD_LAUNCH_TOKEN": launchToken])
    }

    /// 结束一个在线会话，等它真的退出（已经不在线就什么都不做）：托管的给它的进程发 SIGTERM，Pi 优雅收尾，不论这一轮在不在跑；
    /// 终端里开的会话由扩展走 Pi 的正常退出（终端恢复原样、提示怎么恢复这个会话）。没有在 `endTimeout` 内退出抛 `PiHostError.notEnded`。
    public func end(_ id: PiSession.ID) async throws {
        guard let session = bridge.session(id: id) else { return }
        let changes = bridge.changes()  // 先订阅再动手：退出的那一刻不会漏
        if session.hosted {
            stop(session.pid)
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

    // MARK: 进程

    /// 启动并等它的会话连上桥；进程先退出或超时（这时让它退出）都抛错。
    /// 连上的扩展必须读得懂托管约定（报出 `hosted`、协议号相同）：不然起出的进程既不会空闲自退、CuePad 也不认它是托管的，
    /// 成了没人管的孤儿。磁盘上的扩展不是随包版本（接入修复失败、Pi 太旧没修、别人改过）时就是这样，这时让它退出并报错。
    private func launch(
        _ executable: URL, _ arguments: [String], in directory: URL, environment: [String: String]
    ) async throws -> PiSession {
        let changes = bridge.changes()  // 先订阅再启动：连上的那一刻不会漏
        let (exited, exit) = AsyncStream<Void>.makeStream()
        let errors = try Self.scratchFile()
        defer { close(errors) }
        let pid = try Self.spawn(
            executable, ["--mode", "rpc"] + arguments + extraArguments, in: directory, stderr: errors,
            environment: ProcessInfo.processInfo.environment
                .merging(paths.launchEnvironment) { $1 }
                .merging(environment) { $1 }
                .merging([Self.hostedVariable: String(idleLimit.components.seconds), "PATH": Self.path(executable, searchPath)]) { $1 }
        ) {
            exit.yield()
            exit.finish()
        }
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
                throw PiHostError.exited(Self.tail(of: errors))
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw PiHostError.notConnected
            }
            defer { group.cancelAll() }
            return try await group.next() ?? nil
        } }
        let session: PiSession
        do {
            let value = try await withTaskCancellationHandler { try await connecting.value } onCancel: { connecting.cancel() }
            guard let value else { throw CancellationError() }
            session = value
        } catch {
            kill(pid, SIGTERM)
            throw error
        }
        guard session.hosted, session.state != .incompatible else {
            stop(pid)  // 协议号不同而报了 hosted 的，桥上的变化也会让它退出：只发一次
            throw PiHostError.extensionMismatch
        }
        return session
    }

    /// 扩展读这个环境变量判断自己是被 CuePad 托管的，值是空闲多少秒后退出。
    static let hostedVariable = "CUEPAD_HOSTED"

    /// `pi` 是 node 脚本：App 的环境里没有用户 shell 的 PATH，按找 Pi 时的同一组目录补上（node 多半与 pi 装在一起）。
    private static func path(_ executable: URL, _ searchPath: [URL]) -> String {
        ([executable.deletingLastPathComponent()] + searchPath).map(\.path).joined(separator: ":")
    }

    /// 启动一个脱离本进程的 Pi，返回它的 pid；它退出时调 `onExit`（在 App 还活着时回收，App 不在了就归 launchd）。
    /// - 新会话组（`POSIX_SPAWN_SETSID`）：App 所在会话与进程组的信号碰不到它；
    /// - 只继承下面列出的文件描述符（`POSIX_SPAWN_CLOEXEC_DEFAULT`）：App 打开的文件与连接不漏进去；
    /// - 标准输入是一根管道的读端，写端也交给它自己（放在 3 号）：还有写端开着，读端永远读不到 EOF，RPC 模式就不会收尾；
    ///   App 这边启动后立刻关掉两端。否决 `/dev/null`（立刻 EOF）与命名管道（要在磁盘上建、要清理）。
    /// - 标准输出丢到空设备：RPC 的事件与回应走桥，不读；标准错误写进 `stderr`（已删掉名字的临时文件），没连上就退出时读它的末尾当原因。
    private nonisolated static func spawn(
        _ executable: URL, _ arguments: [String], in directory: URL, stderr: Int32, environment: [String: String],
        onExit: @escaping @Sendable () -> Void
    ) throws -> pid_t {
        var lifeline: [Int32] = [0, 0]
        guard pipe(&lifeline) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        defer { close(lifeline[0]); close(lifeline[1]) }
        var actions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_adddup2(&actions, lifeline[0], STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&actions, lifeline[1], 3)
        posix_spawn_file_actions_addopen(&actions, STDOUT_FILENO, "/dev/null", O_WRONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO)
        posix_spawn_file_actions_addchdir(&actions, directory.path)
        var attributes: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }
        var pid: pid_t = 0
        let code = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard code == 0 else { throw POSIXError(.init(rawValue: code) ?? .EIO) }
        reap(pid, onExit: onExit)
        return pid
    }

    /// 一个已删掉名字的临时文件（只剩描述符）：进程退出后随最后一个描述符关闭而释放，不用清理。
    private nonisolated static func scratchFile() throws -> Int32 {
        var template = Array((NSTemporaryDirectory() + "cuepad-pi-XXXXXX").utf8CString)
        let fd = mkstemp(&template)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        unlink(String(cString: template))
        return fd
    }

    /// 标准错误的最后一个非空行（至多 300 个字符）；空为 nil。
    private nonisolated static func tail(of fd: Int32) -> String? {
        var info = stat()
        guard fstat(fd, &info) == 0, info.st_size > 0 else { return nil }
        let count = Int(min(info.st_size, 4096))
        var buffer = [UInt8](repeating: 0, count: count)
        guard pread(fd, &buffer, count, off_t(info.st_size) - off_t(count)) == count else { return nil }
        let line = String(decoding: buffer, as: UTF8.self).split(whereSeparator: \.isNewline)
            .last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { String($0.prefix(300)) }
        return line?.trimmingCharacters(in: .whitespaces)
    }

    /// 等进程退出（内核的进程事件，不轮询）后回收，免得留下僵尸。事件源在退出前一直握着自己。
    /// 注册事件前进程就已退出的话事件不会来：注册后再非阻塞地回收一次兜住这个窗口。
    private nonisolated static func reap(_ pid: pid_t, onExit: @escaping @Sendable () -> Void) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global())
        let once = OnceFlag()
        let finish: @Sendable () -> Void = {
            guard once.claim() else { return }
            source.cancel()
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            onExit()
        }
        source.setEventHandler(handler: finish)
        source.resume()
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == pid, once.claim() {
            source.cancel()
            onExit()
        }
    }

    private final class OnceFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var claimed = false
        func claim() -> Bool { lock.withLock { defer { claimed = true }; return !claimed } }
    }

    /// 让一个托管进程优雅退出（SIGTERM，Pi 的收尾路径）；同一个只发一次。
    private func stop(_ pid: Int32) {
        guard stopping.insert(pid).inserted else { return }
        kill(pid, SIGTERM)
    }

    // MARK: 桥上的变化

    private func handle(_ change: PiSessionChange) {
        switch change {
        case .appeared, .stateChanged:
            settle()
        case .ended(let session, _):
            stopping.remove(session.pid)
            guard session.hosted, let successor = bridge.sessions.first(where: { $0.sessionID == session.sessionID && !$0.hosted }) else { return }
            // 让出的那个退出了：接手的进程把会话重新载入到最新（让出前做完的那一轮它还没看到）
            Task {
                do { try await bridge.reload(successor.id) } catch { Self.log.notice("让接手的会话重新载入失败：\(String(describing: error))") }
            }
        case .infoChanged, .incompatible, .quota:
            break
        }
    }

    /// 按桥上此刻的会话决定哪些托管进程该退：协议号不同的（没有终端能 /reload，下次发消息用新扩展恢复）；
    /// 同一会话在别处也开着、自己又空闲的（正在跑一轮的等它做完、状态变化时再看）。
    private func settle() {
        let sessions = bridge.sessions
        for hosted in sessions where hosted.hosted && !stopping.contains(hosted.pid) {
            if hosted.state == .incompatible {
                stop(hosted.pid)
            } else if !hosted.state.hasPendingWork, sessions.contains(where: { $0.sessionID == hosted.sessionID && !$0.hosted }) {
                stop(hosted.pid)
            }
        }
    }
}

public enum PiHostError: Error, Equatable {
    /// 后台启动的 Pi 还没连上就退出了（Pi 在标准错误里说的最后一句；没说为 nil）
    case exited(String?)
    /// 等了很久 Pi 都没连上（已让它退出）
    case notConnected
    /// 请它结束后一直没退出（多半还卡在需要你在终端里处理的地方）
    case notEnded
    /// Pi 加载的 CuePad 扩展不是这个版本的，不能托管（已让它退出）
    case extensionMismatch
}

extension PiHostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .exited(let reason): "在后台启动的 Pi 没连上就退出了" + (reason.map { "：\($0)" } ?? "")
        case .notConnected: "在后台启动的 Pi 一直没连上"
        case .notEnded: "会话没有按时结束，可能还在等你在终端里处理"
        case .extensionMismatch: "Pi 里的 CuePad 扩展不是这个版本的，没能在后台启动；在 CuePad 设置里修复 Pi 接入后再发"
        }
    }
}
#endif
