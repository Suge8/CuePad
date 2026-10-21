#if os(macOS)
import CueStore
import Darwin
import Foundation
import Observation

/// 本机所有活着的 Agent 会话，实时状态只在内存。每个会话有一条控制通道（`SessionLink`）：Pi 的由这里发现并连接（经扩展的 Unix socket），
/// 其他 Agent 的由各自的适配接上（`attach`、`update`、`detach`），界面、记录器与执行器只认这一处。
///
/// - Pi 会话出现 = 连上 socket 并收到 hello 快照；会话结束 = 连接断开（无心跳、无轮询）。
/// - 目录本身一变（kqueue，`DirectoryWatcher`）就重扫；启动时全量扫描一次。残留 socket（进程被强杀）按文件名里的 pid 判死后删除。
/// - 多个客户端（包括多个 `PiBridge`）可同时连同一会话：各自都收到 hello 与全部状态切换，
///   命令各走各的连接，`ack` 只回给发送方；扩展不做仲裁，命令按到达顺序交给 Pi。
@MainActor @Observable
public final class PiBridge {
    /// 一个在线会话一格。状态变化只改这一格，只有读这一格的视图重算；读 `slots` 的只在会话出现、消失时重算。
    @MainActor @Observable
    public final class Slot: Identifiable {
        /// 会话的身份与工作目录一经连上就不变：只读它们的视图（会话集合、归属项目）不随状态变化重算。
        public nonisolated let id: PiSession.ID
        public nonisolated let sessionID: String
        public nonisolated let cwd: URL
        public internal(set) var session: PiSession
        /// 此刻正在说的这条回答（见 `PiDraft`，刷新节奏见 `PiDraftFeed`）：出字时只有读它的视图重算
        public var draft: PiDraft? { feed.draft }
        /// 有正在说的话（`draft != nil`），只在有无变化时通知：会话行读它不随每个增量重算
        public var speaking: Bool { feed.speaking }
        private let feed = PiDraftFeed()

        init(_ session: PiSession) {
            id = session.id
            sessionID = session.sessionID
            cwd = session.cwd
            self.session = session
        }

        func offer(_ next: PiDraft?) { feed.offer(next) }
    }

    /// 在线会话的格子，按出现先后。界面读会话用这个（列表读 `slots`，每一行读自己那格的 `session`）或 `session(sessionID:)`。
    public internal(set) var slots: [Slot] = []

    /// 在线会话的快照（读了每一格，任何一格变化都会通知读它的视图）：非界面代码与测试用，视图别读。
    public var sessions: [PiSession] { slots.map(\.session) }

    /// 在线会话的文件，会话上线、下线（或换了文件）时给新的一份：历史索引另盯它们（`PiHistoryIndexer.events(following:)`）。
    public var sessionFiles: Observations<Set<URL>, Never> { Observations { Set(self.slots.compactMap(\.session.sessionFile)) } }

    /// 这个 Pi 会话（`sessionID`）在线的那个进程；同一会话开在两个进程里时取先出现的。只随这一个会话的变化通知。
    public func session(sessionID: String) -> PiSession? { slot(sessionID: sessionID)?.session }

    /// 这个会话（`sessionID`）在线的那一格，规则同 `session(sessionID:)`；只随会话出现、消失通知。
    public func slot(sessionID: String) -> Slot? { slots.first { $0.sessionID == sessionID } }

    public func session(id: PiSession.ID) -> PiSession? { slots.first { $0.id == id }?.session }

    @ObservationIgnored let directory: URL
    @ObservationIgnored let hostedIdle: Duration
    @ObservationIgnored var links: [String: Link] = [:]       // socket 文件名（不含 .sock）→ 连接
    /// 在线会话的控制通道（Pi 的就是它的 `Link`）
    @ObservationIgnored var controls: [PiSession.ID: any SessionLink] = [:]
    /// 重开前（`carryOver`）与重新载入扩展前（`detach` 的 `.reload`）各会话的状态与计时：重新上桥时用一次。
    /// 协议号不同的读不到状态，不留也不用：接回时沿用的是它之前读到的
    @ObservationIgnored var carried: [String: (state: PiWorkState, times: PiTimes)] = [:]
    /// 托管的会话歇着的计时（见 `reviewHosted`）
    @ObservationIgnored var idleTimers: [PiSession.ID: Task<Void, Never>] = [:]
    /// 已经请它退出的托管会话：同一个只请一次（Pi 收尾中再收到一次 SIGTERM 会跳过收尾直接退出）
    @ObservationIgnored var releasing: Set<PiSession.ID> = []
    /// 没告别就断开的会话：断开可能先于进程退出（强杀后还是僵尸），留着退出监视，退出时再删残留 socket
    @ObservationIgnored var orphanExitWatchers: [String: ProcessExitWatcher] = [:]
    /// 已报告不兼容的 socket 文件：同一个文件还在时不再重连、不重复报告。按文件本身认（不按名字）：
    /// /reload 在同一路径建的新 socket 名字不变，得照常去连
    @ObservationIgnored var incompatible: [String: PiSocketDirectory.FileIdentity] = [:]
    @ObservationIgnored var watcher: DirectoryWatcher?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<PiSessionChange>.Continuation] = [:]

    /// - Parameter hostedIdle: 托管的 Claude Code、Codex 会话歇着满这么久就请它退出（不算结束，发话时再接着）。
    public init(socketDirectory: URL = PiPaths().socketDirectory, hostedIdle: Duration = AgentTimeouts.hostedIdle) {
        directory = socketDirectory
        self.hostedIdle = hostedIdle
    }

    // MARK: 生命周期

    public func start() throws {
        guard watcher == nil else { return }
        try PiSocketDirectory.prepare(directory)
        watcher = try DirectoryWatcher(directory) { [weak self] in self?.scan() }
        scan()
    }

    public func stop() {
        watcher?.cancel()
        watcher = nil
        for link in links.values { link.connection.close() }
        links = [:]
        controls = [:]
        for timer in idleTimers.values { timer.cancel() }
        idleTimers = [:]
        for watcher in orphanExitWatchers.values { watcher.cancel() }
        orphanExitWatchers = [:]
        slots = []
        for continuation in subscribers.values { continuation.finish() }
        subscribers = [:]
    }

    /// 会话出现/状态切换/结束的事件流（每次调用得到独立的流）。
    public func changes() -> AsyncStream<PiSessionChange> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.subscribers[id] = nil }
            }
        }
    }

    func emit(_ change: PiSessionChange) {
        for continuation in subscribers.values { continuation.yield(change) }
        reviewHosted()
    }
}
#endif
