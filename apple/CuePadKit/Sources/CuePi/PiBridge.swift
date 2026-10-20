#if os(macOS)
import CueStore
import Darwin
import Foundation
import Observation

/// 本机所有活着的 Agent 会话，实时状态只在内存。每个会话有一条控制通道（`SessionLink`）：Pi 的由这里发现并连接（经扩展的 Unix socket），
/// 其他 Agent 的由各自的适配接上（`attach`、`update`、`detach`），界面、记录器与执行器只认这一处。
///
/// - Pi 会话出现 = 连上 socket 并收到 hello 快照；会话结束 = 连接断开（无心跳、无轮询）。
/// - 目录新增由 FSEvents 触发重扫；启动时全量扫描一次。残留 socket（进程被强杀）按文件名里的 pid 判死后删除。
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
    public private(set) var slots: [Slot] = []

    /// 在线会话的快照（读了每一格，任何一格变化都会通知读它的视图）：非界面代码与测试用，视图别读。
    public var sessions: [PiSession] { slots.map(\.session) }

    /// 这个 Pi 会话（`sessionID`）在线的那个进程；同一会话开在两个进程里时取先出现的。只随这一个会话的变化通知。
    public func session(sessionID: String) -> PiSession? { slot(sessionID: sessionID)?.session }

    /// 这个会话（`sessionID`）在线的那一格，规则同 `session(sessionID:)`；只随会话出现、消失通知。
    public func slot(sessionID: String) -> Slot? { slots.first { $0.sessionID == sessionID } }

    /// 这个连接（`PiSession.id`）的会话。
    public func session(id: PiSession.ID) -> PiSession? { slots.first { $0.id == id }?.session }

    @ObservationIgnored private let directory: URL
    @ObservationIgnored private let hostedIdle: Duration
    @ObservationIgnored private var links: [String: Link] = [:]       // socket 文件名（不含 .sock）→ 连接
    /// 在线会话的控制通道（Pi 的就是它的 `Link`）
    @ObservationIgnored private var controls: [PiSession.ID: any SessionLink] = [:]
    /// 重开前（`carryOver`）与重新载入扩展前（`detach` 的 `.reload`）各会话（按会话 id）的状态与计时：重新上桥时用一次。
    /// 协议号不同的读不到状态，不留也不用：接回时沿用的是它之前读到的
    @ObservationIgnored private var carried: [String: (state: PiWorkState, times: PiTimes)] = [:]
    /// 托管的会话歇着的计时（见 `reviewHosted`）
    @ObservationIgnored private var idleTimers: [PiSession.ID: Task<Void, Never>] = [:]
    /// 已经请它退出的托管会话：同一个只请一次（Pi 收尾中再收到一次 SIGTERM 会跳过收尾直接退出）
    @ObservationIgnored private var releasing: Set<PiSession.ID> = []
    /// 没告别就断开的会话：断开可能先于进程退出被确认（强杀后进程还是僵尸），留着它的退出监视，退出时再删残留 socket
    @ObservationIgnored private var orphanExitWatchers: [String: ProcessExitWatcher] = [:]
    /// 已报告不兼容的 socket 文件：同一个文件还在时不再重连，避免每次目录事件都重复报告。按文件本身认（不按名字）：
    /// /reload 在同一路径建的新 socket 名字不变，得照常去连
    @ObservationIgnored private var incompatible: [String: PiSocketDirectory.FileIdentity] = [:]
    @ObservationIgnored private var watcher: FSEventsWatcher?
    @ObservationIgnored private var watchTask: Task<Void, Never>?
    @ObservationIgnored private var subscribers: [UUID: AsyncStream<PiSessionChange>.Continuation] = [:]

    /// 一条已连接的 Pi socket 及其未完成的命令。
    private final class Link: SessionLink {
        let connection: PiSocketConnection
        /// 连上时的那个 socket 文件
        let file: PiSocketDirectory.FileIdentity
        weak var bridge: PiBridge?
        /// 收到 hello 之后的会话
        var id: PiSession.ID?
        let replies = PendingReplies<String, PiWire.Ack>(timeout: AgentTimeouts.ack, timeoutError: PiBridgeError.ackTimeout)
        var nextCommand = 0
        var bye: PiWire.Bye?
        var rejected = false
        var exitWatcher: ProcessExitWatcher?
        init(connection: PiSocketConnection, file: PiSocketDirectory.FileIdentity, bridge: PiBridge) {
            self.connection = connection
            self.file = file
            self.bridge = bridge
        }

        var session: PiSession? { id.flatMap { bridge?.session(id: $0) } }

        func send(_ message: PiMessage) async throws { _ = try await request { try PiWire.sendCommand(id: $0, message) } }

        func command(_ line: String) async throws { _ = try await request { try PiWire.slashCommand(id: $0, line: line) } }

        func reload() async throws { _ = try await request { try PiWire.reloadCommand(id: $0) } }

        /// 托管的（没有终端界面）给进程发 SIGTERM，Pi 优雅收尾（扩展先发 bye），不论这一轮在不在跑；
        /// 终端里开的由扩展走 Pi 的正常退出（终端恢复原样、提示怎么恢复这个会话）。
        func end() async throws {
            guard let session else { throw PiBridgeError.sessionEnded }
            if session.hosted {
                kill(session.pid, SIGTERM)
            } else {
                _ = try await request { try PiWire.endCommand(id: $0) }
            }
        }

        func abort() async throws { _ = try await request { try PiWire.abortCommand(id: $0) } }

        func answer(_ answer: PiAnswerValue, to promptID: String) async throws {
            _ = try await request { try PiWire.answerCommand(id: $0, promptID: promptID, answer) }
        }

        /// 强度先在这里按目标模型夹好（`PiThinkingLevel.clamped`）：Pi 自己的夹法与之不同，界面按这一条显示。
        func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?) async throws {
            let key = model ?? session?.model?.key
            let levels = session?.availableModels.first { $0.key == key }?.thinkingLevels ?? []
            let thinking = thinking?.clamped(to: levels)
            _ = try await request { try PiWire.configCommand(id: $0, model: model, thinking: thinking, name: name) }
        }

        func refreshQuota() async throws { _ = try await request { try PiWire.quotaCommand(id: $0) } }

        private func request(encode: (String) throws -> Data) async throws -> PiWire.Ack {
            guard let session else { throw PiBridgeError.sessionEnded }
            guard session.state != .incompatible else { throw session.upgrading ? PiBridgeError.upgradingExtension : .incompatibleExtension }
            nextCommand += 1
            let commandID = "c\(nextCommand)"
            let data = try encode(commandID)
            let ack = try await replies.request(commandID) { connection.write(data) }
            guard ack.ok else { throw ack.error == "unknown_model" ? PiBridgeError.unknownModel(.pi) : PiBridgeError.rejected(ack.error ?? "unknown") }
            return ack
        }
    }

    /// - Parameter hostedIdle: 托管的 Claude Code、Codex 会话歇着满这么久就请它退出（不算结束，发话时再接着）。
    public init(socketDirectory: URL = PiPaths().socketDirectory, hostedIdle: Duration = AgentTimeouts.hostedIdle) {
        directory = socketDirectory
        self.hostedIdle = hostedIdle
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

    private func emit(_ change: PiSessionChange) {
        for continuation in subscribers.values { continuation.yield(change) }
        reviewHosted()
    }

    // MARK: 命令

    /// 发消息（文字 + 图片），以这句开新一轮：会话歇着就直接开始，在跑就先打断这一轮；打断不了的（`AgentCapabilities.speakBlocked`）
    /// 拒收、带上原因，不排队。受理即返回，不代表模型成功。
    public func send(_ message: PiMessage, to id: PiSession.ID) async throws {
        let link = try control(id, needs: message.images.isEmpty ? [] : .images)
        if let session = session(id: id), let why = session.capabilities.speakBlocked(in: session.state, agent: session.agent) {
            throw PiBridgeError.rejected("failed: \(why)")
        }
        try await link.send(message)
    }

    /// 执行一条斜杠命令（整行，以 / 开头）：Pi 的内置命令由扩展调 Pi 的接口做，扩展命令、提示词模板与 skill 由 Pi 派发；会开一轮的
    /// （模板与 skill 展开成这一轮的提示词）与 `send` 同一规则，在跑就先打断。受理只表示已收下，命令自己的输出只出现在 Agent 的界面里；
    /// 清单里没有的命令抛 `rejected("unknown_command")`，必填参数没给抛 `rejected("missing_argument")`。
    public func command(_ line: String, in id: PiSession.ID) async throws {
        try await control(id, needs: .commands).command(line)
    }

    /// 让该会话从会话文件重新载入到最新（同一会话的另一个进程刚写过文件后）；扩展判断能否安全重载，不能就提示用户。只有 Pi 有。
    public func reload(_ id: PiSession.ID) async throws {
        try await pi(id).reload()
    }

    /// 结束该会话，等它真的下线：托管的进程退出，终端里的会话像在终端里退出那样收尾。没有在 `AgentTimeouts.end` 内下线抛 `notEnded`。
    public func end(_ id: PiSession.ID) async throws {
        let link = try control(id, needs: .end)
        let changes = changes()  // 先订阅再动手：下线的那一刻不会漏
        try await link.end()
        try await withDeadline(AgentTimeouts.end, orThrow: PiBridgeError.notEnded) {
            for await change in changes {
                if case .ended(let ended, _) = change, ended.id == id { return }
            }
            throw CancellationError()
        }
    }

    /// 停止该会话正在跑的这一轮（相当于在 Agent 里按 Esc）：受理即返回，会话随后歇下（`.settled`），能接着说。
    /// 已经空闲时什么也不发生（也成功）；只停它自己这一轮，它派出的子代理照常跑。
    public func abort(_ id: PiSession.ID) async throws {
        try await control(id, needs: .abort).abort()
    }

    /// 回答该会话正在等的弹窗；`promptID` 不是正在等的那个、或答案对不上时抛 `PiBridgeError.rejected`。
    public func answer(_ answer: PiAnswerValue, to promptID: String, in id: PiSession.ID) async throws {
        try await control(id, needs: .answer).answer(answer, to: promptID)
    }

    /// 换该会话的模型、思考强度或会话名（至少给一项，会话名不能是空白）：先换模型再设强度，强度按新模型支持的范围夹取。
    /// 模型不在 Agent 的模型表里抛 `unknownModel`，提供方没配好密钥抛 `rejected("no_auth")`；成功后会话的上报（`model`、`thinking`）随 `infoChanged` 更新。
    public func configure(model: PiModelKey? = nil, thinking: PiThinkingLevel? = nil, name: String? = nil, in id: PiSession.ID) async throws {
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard model != nil || thinking != nil || name != nil, name?.isEmpty != true else { throw PiBridgeError.rejected("bad_request") }
        var needs: AgentCapabilities = model != nil || thinking != nil ? .model : []
        if name != nil { needs.insert(.rename) }
        try await control(id, needs: needs).configure(model: model, thinking: thinking, name: name)
    }

    /// 请该会话查一次所有 OAuth 订阅的额度：查到的随 `changes()` 的 `.quota` 报出（与回复里带回的同一条路），
    /// 再返回；有一家没查到抛 `rejected("failed: …")`（查到的那几家照常报出）。只有 Pi 有。
    public func refreshQuota(in id: PiSession.ID) async throws {
        try await pi(id).refreshQuota()
    }

    /// 会话的控制通道；这个 Agent 的这类会话做不到（`AgentCapabilities`）就抛 `unsupported`：能做什么只看能力表，通道不再判断。
    private func control(_ id: PiSession.ID, needs: AgentCapabilities) throws -> any SessionLink {
        guard let link = controls[id], let session = session(id: id) else { throw PiBridgeError.unknownSession(id) }
        guard session.capabilities.isSuperset(of: needs) else { throw PiBridgeError.unsupported }
        return link
    }

    private func pi(_ id: PiSession.ID) throws -> Link {
        guard let link = controls[id] else { throw PiBridgeError.unknownSession(id) }
        guard let pi = link as? Link else { throw PiBridgeError.unsupported }
        return pi
    }

    // MARK: 会话的上线、变化、下线（Pi 与其他 Agent 的适配同一条路）

    /// CuePad 重开前各会话记下的状态与计时（启动对账时从同步记录里取，`PiStateRecorder.reset`）。
    public func carryOver(_ before: [String: (state: PiWorkState, times: PiTimes)]) { carried = before }

    /// 一个会话上线（发现了它，或 CuePad 刚开了它）：之后的命令交给 `link`。同一 id 已在线时只换通道与快照，不重报出现。
    /// 状态的起点只有这一处定：重新上桥（同一 id 换了快照、重新载入扩展、CuePad 重开后接回）时粗状态（`PiWorkState.phase`）没变就沿用原来的起点，
    /// 各家接入上桥时给的"现在"不算——界面的"多久前""有新回复"与同步记录都读它。
    public func attach(_ session: PiSession, via link: any SessionLink) {
        controls[session.id] = link
        var session = session
        let before = slots.first { $0.id == session.id && $0.session.state != .incompatible }.map(\.session.carried)
            ?? (session.state == .incompatible ? nil : carried.removeValue(forKey: session.sessionID))
        if let before, before.state.phase == session.state.phase {
            session.stateSince = before.times.stateSince
            session.busySince = before.times.busySince ?? session.busySince
        }
        guard let slot = slots.first(where: { $0.id == session.id }) else {
            slots.append(Slot(session))
            return emit(.appeared(session))
        }
        replace(slot, with: session)
    }

    /// 改一个在线会话的快照：状态或那句说明变了报 `stateChanged`，否则报 `infoChanged`；没有变化不报。不在线时什么也不做。
    public func update(_ id: PiSession.ID, _ change: (inout PiSession) -> Void) {
        guard let slot = slots.first(where: { $0.id == id }) else { return }
        var session = slot.session
        change(&session)
        replace(slot, with: session)
    }

    private func replace(_ slot: Slot, with session: PiSession) {
        let previous = slot.session
        guard session != previous else { return }
        slot.session = session
        emit(session.state != previous.state || session.detail != previous.detail ? .stateChanged(session, from: previous.state) : .infoChanged(session))
    }

    /// 改一个在线会话正在说的话（`PiDraft`）：各家接入每个增量调一次即可，刷新节奏由 `PiDraftFeed` 统一定；只改这一格的 `draft`，
    /// 不经 `changes()`（不进记录器、不进同步）。不在线时什么也不做；会话下线时随它的格子一起没了。
    public func setDraft(_ id: PiSession.ID, _ draft: PiDraft?) {
        slots.first { $0.id == id }?.offer(draft)
    }

    /// 一个会话下线（进程退出、会话结束）。
    public func detach(_ id: PiSession.ID, reason: PiSessionEndReason) {
        controls[id] = nil
        idleTimers.removeValue(forKey: id)?.cancel()
        releasing.remove(id)
        guard let index = slots.firstIndex(where: { $0.id == id }) else { return }
        let session = slots.remove(at: index).session
        if reason == .reload, session.state != .incompatible { carried[session.sessionID] = session.carried }
        emit(.ended(session, reason: reason))
    }

    // MARK: 托管的会话

    /// 从这个扩展版本起，扩展换了新版本就在空闲时自己重新载入（`PiSession.upgrading`）；更早的协议号不同时要在终端里 /reload。
    nonisolated static let selfReloadingExtension = 29

    /// 托管的会话什么时候请它退出（不算结束，发话时再接着）：同一会话在别处（终端里）也开着、自己又空闲的（两边会各写各的；正在跑一轮的等它做完、状态变化时再看）；
    /// 歇着满 `hostedIdle` 的（为自己起了进程的 Claude Code、Codex；Pi 自己计时，App 退出后照常在；OpenCode 的会话在它的服务里，没有进程要关）。
    private func reviewHosted() {
        for slot in slots where slot.session.hosted && !releasing.contains(slot.id) {
            let session = slot.session
            let busy = session.state.hasPendingWork
            let elsewhere = slots.contains { $0.session.agent == session.agent && $0.sessionID == session.sessionID && !$0.session.hosted }
            if !busy && elsewhere {
                release(session.id)
            } else if session.agent == .pi || session.agent == .opencode {
                continue
            } else if busy {
                idleTimers.removeValue(forKey: session.id)?.cancel()
            } else if idleTimers[session.id] == nil {
                let id = session.id, limit = hostedIdle
                idleTimers[id] = Task { [weak self] in
                    guard (try? await Task.sleep(for: limit)) != nil else { return }
                    self?.release(id)
                }
            }
        }
    }

    private func release(_ id: PiSession.ID) {
        guard let link = controls[id], releasing.insert(id).inserted else { return }
        idleTimers.removeValue(forKey: id)?.cancel()
        Task { try? await link.end() }
    }

    // MARK: 发现

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let present = Set(names.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(".sock".count)) })
        incompatible = incompatible.filter { present.contains($0.key) }
        for name in present where links[name] == nil { connect(name) }
    }

    private func socketPath(_ name: String) -> String { directory.appending(path: name + ".sock").path }

    private func connect(_ name: String) {
        let path = socketPath(name)
        guard PiSocketDirectory.isOwnSocket(path), let file = PiSocketDirectory.identity(of: path), incompatible[name] != file else { return }
        do {
            let link = Link(connection: try PiSocketConnection(path: path), file: file, bridge: self)
            links[name] = link
            Task { await consume(link, name: name) }
        } catch UnixSocket.Failure.connect(let code) where code == ECONNREFUSED {
            removeIfStale(name)
        } catch UnixSocket.Failure.connect(let code) where code == ENOENT {
            // 扫描与文件删除之间的竞态
        } catch {
            incompatible[name] = file
            emit(.incompatible(id: name, detail: "cannot connect: \(error)"))
        }
    }

    /// 连不上（ECONNREFUSED，没人在 listen）的 socket：属主 pid 已死是强杀残留，删；还活着就不删、不重试——扩展先 listen
    /// 再收紧成 0600，收紧产生的目录事件会再触发一次扫描（/reload 时扫到的还没删的旧文件同理，新文件随后出现）。
    @discardableResult
    private func removeIfStale(_ name: String) -> Bool {
        guard let pid = PiSocketDirectory.pid(fromSocketName: name + ".sock"), PiSocketDirectory.processIsDead(pid) else { return false }
        return unlink(socketPath(name)) == 0
    }

    // MARK: 读循环

    private func consume(_ link: Link, name: String) async {
        for await line in link.connection.lines {
            // 协议版本不同的会话：之后的消息格式不可知，只认告别（同 hello 只读认得出的一项：重载的告别要认得出，`PiSessionEndReason.reload`），等连接断开
            if link.session?.state == .incompatible {
                link.bye = PiWire.otherProtocolBye(line) ?? link.bye
                continue
            }
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
            guard link.id == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            guard let work = hello.state.work else { throw HandlingError.unknownState(hello.state.kind) }
            var session = PiSession(
                id: name, sessionID: hello.sessionId, agent: .pi, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid,
                cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory), terminal: PiTerminal(tty: hello.tty, environment: hello.term),
                extensionVersion: hello.extensionVersion, state: work.state, detail: work.detail,
                errorMessage: hello.state.errorMessage, stateSince: hello.state.sinceDate, busySince: hello.state.busySinceDate)
            session.turnStartedAt = hello.state.turnSinceDate
            hello.info.apply(to: &session)
            session.launchToken = hello.launchToken
            session.hosted = hello.hosted ?? false
            appear(session, on: link)
        case .otherProtocol(let hello):
            guard link.id == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            var session = PiSession(
                id: name, sessionID: hello.sessionId, agent: .pi, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid, cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory),
                terminal: PiTerminal(), extensionVersion: hello.extensionVersion, state: .incompatible, stateSince: Date())
            session.name = hello.name
            session.firstMessage = hello.firstMessage
            session.hosted = hello.hosted
            appear(session, on: link)
        case .state(let wire):
            guard let id = link.id else { throw HandlingError.messageBeforeHello }
            guard let work = wire.work else { throw HandlingError.unknownState(wire.kind) }
            update(id) { session in
                session.state = work.state
                session.detail = work.detail
                session.errorMessage = wire.errorMessage
                session.stateSince = wire.sinceDate
                session.busySince = wire.busySinceDate
                session.turnStartedAt = wire.turnSinceDate
            }
        case .info(let info):
            guard let id = link.id else { throw HandlingError.messageBeforeHello }
            update(id) { info.apply(to: &$0) }
        case .ack(let ack):
            if let id = ack.id { link.replies.resolve(id, with: .success(ack)) }
        case .bye(let bye):
            link.bye = bye
        case .draft(let draft):
            guard let session = link.session else { throw HandlingError.messageBeforeHello }
            setDraft(session.id, draft)
        case .quota(let report):
            guard link.id != nil else { throw HandlingError.messageBeforeHello }
            emit(.quota(report))
        }
    }

    private enum HandlingError: Error {
        case duplicateHello, nameMismatch, unknownState(String), messageBeforeHello
    }

    private func appear(_ session: PiSession, on link: Link) {
        link.id = session.id
        link.exitWatcher = ProcessExitWatcher(pid: session.pid) { [weak self] in self?.processExited(session.id) }
        attach(session, via: link)
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
        link.replies.closeAll(PiBridgeError.sessionEnded)
        // 没有告别就断开 = 进程被强杀，socket 文件会残留：进程已确认退出就现在删，否则等它的退出通知
        if link.bye == nil, link.id != nil, !removeIfStale(name), let watcher = link.exitWatcher {
            orphanExitWatchers[name] = watcher
        } else {
            link.exitWatcher?.cancel()
        }
        if let id = link.id {
            detach(id, reason: link.bye.map { .closed(reason: $0.reason) } ?? .disconnected)
        }
        // /reload：同一进程在同一路径重新 listen。新文件的目录事件可能在这条连接还挂着时就被扫过（扫描跳过有连接的名字），
        // 之后不会再有事件，所以收尾时文件还在就当场连一次；还是旧文件（扩展还没删）时连不上，新文件的事件随后会到
        if FileManager.default.fileExists(atPath: socketPath(name)) { connect(name) }
    }
}
#endif
