#if os(macOS)
import CueStore
import Darwin
import Foundation
import Observation

extension PiBridge {
    final class Link: SessionLink {
        let connection: PiSocketConnection
        let file: PiSocketDirectory.FileIdentity
        weak var bridge: PiBridge?
        /// 收到 hello 之后的会话
        var id: PiSession.ID?
        /// hello 里报的扩展版本
        var extensionVersion: Int?
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

        func send(_ message: PiMessage, in _: PiSession.ID) async throws { _ = try await request { try PiWire.sendCommand(id: $0, message) } }

        func command(_ line: String, in _: PiSession.ID) async throws { _ = try await request { try PiWire.slashCommand(id: $0, line: line) } }

        func reload() async throws { _ = try await request { try PiWire.bare("reload", id: $0) } }

        /// 退出方式由扩展按真实 mode 选择，不按 hosted 猜模式，也不对外部 PID 发信号。
        func end(_: PiSession.ID) async throws { _ = try await request { try PiWire.bare("end", id: $0) } }

        func abort(_: PiSession.ID) async throws { _ = try await request { try PiWire.bare("abort", id: $0) } }

        func retry(_: PiSession.ID) async throws { _ = try await request { try PiWire.bare("retry", id: $0) } }

        func answer(_ answer: PiAnswerValue, to promptID: String, in _: PiSession.ID) async throws {
            _ = try await request { try PiWire.answerCommand(id: $0, promptID: promptID, answer) }
        }

        func configure(_ config: PiConfig, in _: PiSession.ID) async throws {
            let key = config.model ?? session?.model?.key
            let levels = session?.availableModels.first { $0.key == key }?.thinkingLevels ?? []
            let thinking = config.thinking?.clamped(to: levels)
            _ = try await request { try PiWire.configCommand(id: $0, model: config.model, thinking: thinking, fast: config.fast, name: config.name) }
        }

        /// 强度先在这里按目标模型夹好（`PiThinkingLevel.clamped`）：Pi 自己的夹法与之不同，界面按这一条显示。
        func configure(model: PiModelKey?, thinking: PiThinkingLevel?, name: String?, in id: PiSession.ID) async throws {
            try await configure(PiConfig(model: model, thinking: thinking, name: name), in: id)
        }

        /// 报的扩展版本不是随包版本（没报的也算）：请它核对磁盘（`PiWire.upgrade`）。磁盘上还是旧的它就不动，所以可以多说。
        func offerUpgrade() {
            guard extensionVersion != PiExtensionBundle.version else { return }
            connection.write(PiWire.upgrade)
        }

        func refreshQuota() async throws { _ = try await request { try PiWire.bare("quota", id: $0) } }

        private func request(encode: (String) throws -> Data) async throws -> PiWire.Ack {
            guard let session else { throw PiBridgeError.sessionEnded }
            guard !session.upgrading else { throw PiBridgeError.upgradingExtension }
            nextCommand += 1
            let commandID = "c\(nextCommand)"
            let data = try encode(commandID)
            let ack = try await replies.request(commandID) { connection.write(data) }
            guard !ack.ok else { return ack }
            // 旧扩展不认比它新的命令（`PiWire.oldestExtension`）：换上新扩展后才做得到
            throw ack.error == "unknown_model" ? PiBridgeError.unknownModel(.pi) : PiBridgeError.rejected(ack.error ?? "unknown")
        }
    }

    /// 连着的 Pi 会话都报了这个扩展版本（还没 hello 的不算）：过渡时判断旧单文件扩展还有没有会话在用
    /// （`AgentIntegration.retireLegacyPiExtension`）。连接在扫描 socket 目录时同步建立，所以已在跑的会话都算在内。
    public func allRun(extensionVersion version: Int) -> Bool { links.values.allSatisfy { $0.extensionVersion == version } }

    /// 装完新版扩展后：请连着的旧版会话换上（握手时版本不同的已在握手时请过，那时磁盘上可能还是旧的）。
    public func offerExtensionUpgrade() { for link in links.values where link.id != nil { link.offerUpgrade() } }

    func scan() {
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

    /// 连不上（ECONNREFUSED，没人在 listen）的 socket：属主 pid 已死是强杀残留，删；还活着就不删、不重试——扩展 listen 好才把 socket
    /// 改名进来，活着的进程留下的没人 listen 的只有 /reload 时还没删的旧文件，新文件改名进来时目录会再变一次。
    @discardableResult
    private func removeIfStale(_ name: String) -> Bool {
        guard let pid = PiSocketDirectory.pid(fromSocketName: name + ".sock"), PiSocketDirectory.processIsDead(pid) else { return false }
        return unlink(socketPath(name)) == 0
    }

    // MARK: 读循环

    private func consume(_ link: Link, name: String) async {
        for await line in link.connection.lines {
            // 读不懂的扩展：之后的消息格式不可知，只认告别（同 hello 只读认得出的一项：重载的告别要认得出，`PiSessionEndReason.reload`），等连接断开
            if link.session?.upgrading == true {
                link.bye = PiWire.identityBye(line) ?? link.bye
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
                state: work.state, detail: work.detail,
                errorMessage: hello.state.errorMessage, stateSince: hello.state.sinceDate, busySince: hello.state.busySinceDate)
            session.turnStartedAt = hello.state.turnSinceDate
            hello.info.apply(to: &session)
            session.launchToken = hello.launchToken
            link.extensionVersion = hello.extensionVersion
            session.hosted = hello.hosted ?? false
            appear(session, on: link)
            link.offerUpgrade()
        case .upgrading(let hello):
            guard link.id == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            var session = PiSession(
                id: name, sessionID: hello.sessionId, agent: .pi, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid, cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory),
                terminal: PiTerminal(), state: .settled, upgrading: true, stateSince: Date())
            session.name = hello.name
            session.firstMessage = hello.firstMessage
            session.hosted = hello.hosted
            link.extensionVersion = hello.extensionVersion
            appear(session, on: link)
            link.offerUpgrade()
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
