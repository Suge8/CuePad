#if os(macOS)
import CueStore
import Darwin
import Foundation
import Observation

extension PiBridge {
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
            // 协议版本不同的会话：之后的消息格式不可知，只认告别（同 hello 只读认得出的一项：重载的告别要认得出，`PiSessionEndReason.reload`），等连接断开
            if link.session?.upgrading == true {
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
                state: work.state, detail: work.detail,
                errorMessage: hello.state.errorMessage, stateSince: hello.state.sinceDate, busySince: hello.state.busySinceDate)
            session.turnStartedAt = hello.state.turnSinceDate
            hello.info.apply(to: &session)
            session.launchToken = hello.launchToken
            link.extensionVersion = hello.extensionVersion
            session.hosted = hello.hosted ?? false
            appear(session, on: link)
        case .otherProtocol(let hello):
            guard link.id == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            var session = PiSession(
                id: name, sessionID: hello.sessionId, agent: .pi, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid, cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory),
                terminal: PiTerminal(), state: .settled, upgrading: true, stateSince: Date())
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
