#if os(macOS)
import Darwin
import Foundation
import Observation

/// 发现并连接本机所有活着的 Pi 会话（经扩展的 Unix socket），实时状态只在内存。
///
/// - 会话出现 = 连上 socket 并收到 hello 快照；会话结束 = 连接断开（无心跳、无轮询）。
/// - 目录新增由 FSEvents 触发重扫；启动时全量扫描一次。残留 socket（进程被强杀）按文件名里的 pid 判死后删除。
/// - 多个客户端（包括多个 `PiBridge`）可同时连同一会话：各自都收到 hello 与全部状态切换，
///   命令各走各的连接，`ack` 只回给发送方；扩展不做仲裁，命令按到达顺序交给 Pi。
@MainActor @Observable
public final class PiBridge {
    public private(set) var sessions: [PiSession] = []

    @ObservationIgnored private let directory: URL
    /// 本次运行里已结束的会话（最后一刻的快照），按 id。界面据此把还指向它的发送目标显示成"已结束"，而不是悄悄丢掉；
    /// 同一个 Pi 会话重新打开会是新的 id（含进程号），从 `sessions` 里按 `sessionID` 找。
    public private(set) var endedSessions: [PiSession.ID: PiSession] = [:]
    @ObservationIgnored private var links: [String: Link] = [:]       // socket 文件名（不含 .sock）→ 连接
    /// 没告别就断开的会话：断开可能先于进程退出被确认（强杀后进程还是僵尸），留着它的退出监视，退出时再删残留 socket
    @ObservationIgnored private var orphanExitWatchers: [String: ProcessExitWatcher] = [:]
    /// 已经重试过一次的"被拒绝"socket：文件还在时不再排重试，之后只在目录事件/重扫时再看
    @ObservationIgnored private var retried: Set<String> = []
    /// 已报告不兼容的 socket 文件：同一个文件还在时不再重连，避免每次目录事件都重复报告。按文件本身认（不按名字）：
    /// /reload 在同一路径建的新 socket 名字不变，得照常去连
    @ObservationIgnored private var incompatible: [String: PiSocketDirectory.FileIdentity] = [:]
    @ObservationIgnored private var watcher: FSEventsWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<PiSessionChange>.Continuation] = [:]

    /// 一条已连接的 socket 及其未完成的命令。
    private final class Link {
        let connection: PiSocketConnection
        /// 连上时的那个 socket 文件
        let file: PiSocketDirectory.FileIdentity
        var session: PiSession?
        var pending: [String: CheckedContinuation<PiWire.Ack, any Error>] = [:]
        var nextCommand = 0
        var byeReason: String?
        var rejected = false
        var exitWatcher: ProcessExitWatcher?
        init(connection: PiSocketConnection, file: PiSocketDirectory.FileIdentity) {
            self.connection = connection
            self.file = file
        }
    }

    private static let ackTimeout: Duration = .seconds(10)
    /// 对"进程活着但还没 listen"的 socket 只重试一次；之后由下一次目录事件/重扫再看
    private static let retryDelay: Duration = .milliseconds(200)

    public init(socketDirectory: URL = PiPaths().socketDirectory) {
        directory = socketDirectory
    }

    // MARK: 生命周期

    public func start() throws {
        guard watcher == nil else { return }
        try PiSocketDirectory.prepare(directory)
        let watcher = FSEventsWatcher(root: directory)
        self.watcher = watcher
        watchTask = Task { [weak self] in
            for await _ in watcher.paths { self?.scan() }
        }
        scan()
    }

    public func stop() {
        watchTask?.cancel()
        watchTask = nil
        watcher?.stop()
        watcher = nil
        for link in links.values { link.connection.close() }
        links = [:]
        for watcher in orphanExitWatchers.values { watcher.cancel() }
        orphanExitWatchers = [:]
        sessions = []
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

    private func emit(_ change: PiSessionChange) {
        for continuation in subscribers.values { continuation.yield(change) }
    }

    // MARK: 命令

    /// 发消息（文字 + 图片）。返回会话受理时的投递方式；`ack` 只表示已受理，不代表模型成功。
    @discardableResult
    public func send(_ message: PiMessage, to id: PiSession.ID) async throws -> PiDelivery {
        let ack = try await request(to: id) { try PiWire.sendCommand(id: $0, message) }
        switch ack.delivered {
        case "steer": return .queued(.steer)
        case "followUp": return .queued(.followUp)
        default: return .immediate
        }
    }

    /// 执行一条斜杠命令（整行，以 / 开头）：内置命令由扩展调 Pi 的接口做，扩展命令、提示词模板与 skill 由 Pi 派发（模板与 skill 展开成这一轮的提示词，
    /// 会话正忙时按 `whenBusy` 入队，缺省等它做完再说）。`ack` 只表示已受理，扩展命令自己的输出只出现在 Pi 的界面里；
    /// 清单里没有的命令抛 `rejected("unknown_command")`，必填参数没给抛 `rejected("missing_argument")`。
    public func command(_ line: String, whenBusy: PiQueueMode? = nil, in id: PiSession.ID) async throws {
        _ = try await request(to: id) { try PiWire.slashCommand(id: $0, line: line, whenBusy: whenBusy) }
    }

    /// 把文字粘贴进该会话的输入框（不发送）。

    /// 让该会话从会话文件重新载入到最新（同一会话的另一个进程刚写过文件后）；扩展判断能否安全重载，不能就提示用户。
    public func reload(_ id: PiSession.ID) async throws {
        _ = try await request(to: id) { try PiWire.reloadCommand(id: $0) }
    }

    /// 请该会话的扩展让 Pi 正常退出（`ack` 即已受理，退出随后发生，会话结束以 `.ended` 报告）。托管的进程用 `PiHost.end`，它等到真的退出。
    public func end(_ id: PiSession.ID) async throws {
        _ = try await request(to: id) { try PiWire.endCommand(id: $0) }
    }

    /// 停止该会话正在跑的这一轮（相当于在 Pi 里按 Esc）：`ack` 即已受理，会话随后以"被中止"歇下（`.done(aborted: true)`），能接着说。
    /// 指挥官已经空闲时什么也不发生（也成功）；只停指挥官自己这一轮，它派出的子代理照常跑。
    public func abort(_ id: PiSession.ID) async throws {
        _ = try await request(to: id) { try PiWire.abortCommand(id: $0) }
    }

    /// 回答该会话正在等的弹窗；`promptID` 不是正在等的那个、或答案对不上时抛 `PiBridgeError.rejected`。
    public func answer(_ answer: PiPromptAnswer, to promptID: String, in id: PiSession.ID) async throws {
        _ = try await request(to: id) { try PiWire.answerCommand(id: $0, promptID: promptID, answer) }
    }

    /// 换该会话的模型、思考强度（至少给一项）：先换模型再设强度，强度按新模型支持的范围夹取。
    /// 模型不在 Pi 的模型表里抛 `rejected("unknown_model")`，提供方没配好密钥抛 `rejected("no_auth")`；成功后会话的上报（`model`、`thinking`）随 `infoChanged` 更新。
    public func configure(model: PiModelRef? = nil, thinking: String? = nil, name: String? = nil, in id: PiSession.ID) async throws {
        _ = try await request(to: id) { try PiWire.configCommand(id: $0, model: model, thinking: thinking, name: name) }
    }

    private func request(to id: PiSession.ID, encode: (String) throws -> Data) async throws -> PiWire.Ack {
        guard let link = links[id], let session = link.session else { throw PiBridgeError.unknownSession(id) }
        guard session.state != .incompatible else { throw PiBridgeError.incompatibleExtension }
        link.nextCommand += 1
        let commandID = "c\(link.nextCommand)"
        let data = try encode(commandID)
        let ack: PiWire.Ack = try await withCheckedThrowingContinuation { continuation in
            link.pending[commandID] = continuation
            link.connection.write(data)
            Task { [weak link] in
                try? await Task.sleep(for: Self.ackTimeout)
                link?.pending.removeValue(forKey: commandID)?.resume(throwing: PiBridgeError.ackTimeout)
            }
        }
        guard ack.ok else { throw PiBridgeError.rejected(ack.error ?? "unknown") }
        return ack
    }

    // MARK: 发现

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let present = Set(names.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(".sock".count)) })
        incompatible = incompatible.filter { present.contains($0.key) }
        retried.formIntersection(present)
        for name in present where links[name] == nil { connect(name) }
    }

    private func socketPath(_ name: String) -> String { directory.appending(path: name + ".sock").path }

    private func connect(_ name: String) {
        let path = socketPath(name)
        guard PiSocketDirectory.isOwnSocket(path), let file = PiSocketDirectory.identity(of: path), incompatible[name] != file else { return }
        do {
            let link = Link(connection: try PiSocketConnection(path: path), file: file)
            links[name] = link
            Task { await consume(link, name: name) }
        } catch PiSocketConnection.ConnectError.connect(let code) where code == ECONNREFUSED {
            handleRefused(name)
        } catch PiSocketConnection.ConnectError.connect(let code) where code == ENOENT {
            // 扫描与文件删除之间的竞态
        } catch {
            incompatible[name] = file
            emit(.incompatible(id: name, detail: "cannot connect: \(error)"))
        }
    }

    /// ECONNREFUSED = 没人在 listen。属主 pid 已死 → 强杀残留，删；pid 还活着 → 可能刚 bind 还没 listen，不删。
    private func handleRefused(_ name: String) {
        if removeIfStale(name) { return }
        guard retried.insert(name).inserted else { return }
        Task {
            try? await Task.sleep(for: Self.retryDelay)
            if links[name] == nil { connect(name) }
        }
    }

    @discardableResult
    private func removeIfStale(_ name: String) -> Bool {
        guard let pid = PiSocketDirectory.pid(fromSocketName: name + ".sock"), PiSocketDirectory.processIsDead(pid) else { return false }
        return unlink(socketPath(name)) == 0
    }

    // MARK: 读循环

    private func consume(_ link: Link, name: String) async {
        for await line in link.connection.lines {
            // 协议版本不同的会话：之后的消息格式不可知，只等连接断开
            if link.session?.state == .incompatible { continue }
            do {
                try handle(try PiWire.decode(line), on: link, name: name)
            } catch {
                reject(link, name: name, detail: "\(error)")
            }
            if link.rejected { break }
        }
        finish(link, name: name)
    }

    private func handle(_ message: PiWire.Message, on link: Link, name: String) throws {
        switch message {
        case .hello(let hello):
            guard link.session == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            guard let state = hello.state.agentState else { throw HandlingError.unknownState(hello.state.kind) }
            var session = PiSession(
                id: name, sessionID: hello.sessionId, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid,
                cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory), mode: hello.mode,
                terminal: PiTerminal(tty: hello.tty, environment: hello.term), extensionVersion: hello.extensionVersion,
                state: state, stateSince: hello.state.sinceDate, busySince: hello.state.busySinceDate)
            hello.info.apply(to: &session)
            session.launchToken = hello.launchToken
            session.hosted = hello.hosted ?? false
            appear(session, on: link)
        case .otherProtocol(let hello):
            guard link.session == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            var session = PiSession(
                id: name, sessionID: hello.sessionId, sessionFile: nil, pid: hello.pid, cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory),
                mode: "", terminal: PiTerminal(), extensionVersion: hello.extensionVersion, state: .incompatible, stateSince: Date())
            session.name = hello.name
            session.firstMessage = hello.firstMessage
            appear(session, on: link)
        case .state(let wire):
            guard var session = link.session else { throw HandlingError.messageBeforeHello }
            guard let state = wire.agentState else { throw HandlingError.unknownState(wire.kind) }
            let previous = session.state
            session.state = state
            session.stateSince = wire.sinceDate
            session.busySince = wire.busySinceDate
            update(session, on: link)
            emit(.stateChanged(session, from: previous))
        case .info(let info):
            guard var session = link.session else { throw HandlingError.messageBeforeHello }
            info.apply(to: &session)
            update(session, on: link)
            emit(.infoChanged(session))
        case .ack(let ack):
            if let id = ack.id { link.pending.removeValue(forKey: id)?.resume(returning: ack) }
        case .bye(let reason):
            link.byeReason = reason
        }
    }

    private enum HandlingError: Error {
        case duplicateHello, nameMismatch, unknownState(String), messageBeforeHello
    }

    private func appear(_ session: PiSession, on link: Link) {
        link.session = session
        link.exitWatcher = ProcessExitWatcher(pid: session.pid) { [weak self] in
            Task { @MainActor in self?.processExited(session.id) }
        }
        sessions.append(session)
        emit(.appeared(session))
    }

    private func update(_ session: PiSession, on link: Link) {
        link.session = session
        if let index = sessions.firstIndex(where: { $0.id == session.id }) { sessions[index] = session }
    }

    /// 不兼容/损坏：报告并断开。会话若已出现，随后走正常的结束路径。
    private func reject(_ link: Link, name: String, detail: String) {
        link.rejected = true
        incompatible[name] = link.file
        emit(.incompatible(id: name, detail: detail))
        link.connection.close()
    }

    /// 进程已退出：它的 socket 文件若还在（强杀）就删掉。正常退出时扩展自己已删。
    private func processExited(_ name: String) {
        let path = socketPath(name)
        if PiSocketDirectory.isOwnSocket(path) { unlink(path) }
        orphanExitWatchers.removeValue(forKey: name)?.cancel()
    }

    private func finish(_ link: Link, name: String) {
        links[name] = nil
        for continuation in link.pending.values { continuation.resume(throwing: PiBridgeError.sessionEnded) }
        link.pending = [:]
        // 没有告别就断开 = 进程被强杀，socket 文件会残留：进程已确认退出就现在删，否则等它的退出通知
        if link.byeReason == nil, link.session != nil, !removeIfStale(name), let watcher = link.exitWatcher {
            orphanExitWatchers[name] = watcher
        } else {
            link.exitWatcher?.cancel()
        }
        if let session = link.session {
            sessions.removeAll { $0.id == session.id }
            endedSessions[session.id] = session
            emit(.ended(session, reason: link.byeReason.map { .closed(reason: $0) } ?? .disconnected))
        }
        // /reload：同一进程在同一路径重新 listen。新文件的目录事件可能在这条连接还挂着时就被扫过（扫描跳过有连接的名字），
        // 之后不会再有事件，所以收尾时文件还在就当场连一次；还是旧文件（扩展还没删）时连不上，新文件的事件随后会到
        if FileManager.default.fileExists(atPath: socketPath(name)) { connect(name) }
    }
}
#endif
