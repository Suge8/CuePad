#if os(macOS)
import CueStore
import Darwin
import Foundation

/// 会话快照只经桥的 attach/update/detach 发布。多个桥可连接同一扩展；ack 只回发送方，命令按扩展收到的顺序执行。
@MainActor
final class PiConnections {
    private let directory: URL
    weak var bridge: Bridge?
    private var links: [String: PiConnection] = [:]
    private var watcher: DirectoryWatcher?
    // 没告别就断线可能早于进程退出，等退出后再清残留 socket。
    private var orphanExitWatchers: [String: ProcessExitWatcher] = [:]
    // 同名 socket 重建后必须重连，所以按文件身份记不兼容，而非名字。
    private var incompatible: [String: SocketDirectory.FileIdentity] = [:]

    init(directory: URL) {
        self.directory = directory
    }

    func start() throws {
        guard watcher == nil else { return }
        try SocketDirectory.prepare(directory)
        watcher = try DirectoryWatcher(directory) { [weak self] in self?.scan() }
        scan()
    }

    func stop() {
        watcher?.cancel()
        watcher = nil
        for link in links.values {
            link.connection.close()
            link.exitWatcher?.cancel()
            link.replies.closeAll(BridgeError.sessionEnded)
        }
        links = [:]
        for watcher in orphanExitWatchers.values { watcher.cancel() }
        orphanExitWatchers = [:]
    }

    private func scan() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let present = Set(names.filter { $0.hasSuffix(".sock") }.map { String($0.dropLast(".sock".count)) })
        incompatible = incompatible.filter { present.contains($0.key) }
        for name in present where links[name] == nil { connect(name) }
    }

    private func socketPath(_ name: String) -> String { directory.appending(path: name + ".sock").path }

    private func connect(_ name: String) {
        guard let bridge else { return }
        let path = socketPath(name)
        guard SocketDirectory.isOwnSocket(path), let file = SocketDirectory.identity(of: path), incompatible[name] != file else { return }
        do {
            let link = PiConnection(connection: try SocketConnection(path: path), file: file, bridge: bridge)
            links[name] = link
            Task { await consume(link, name: name) }
        } catch UnixSocket.Failure.connect(let code) where code == ECONNREFUSED {
            removeIfStale(name)
        } catch UnixSocket.Failure.connect(let code) where code == ENOENT {
            // 扫描与文件删除之间的竞态
        } catch {
            incompatible[name] = file
            bridge.emit(.incompatible(id: name, detail: "cannot connect: \(error)"))
        }
    }

    /// 还活着的不删、不重试：扩展 listen 好才把 socket 改名进来，活着的进程留下的没人 listen 的只有 /reload 时还没删的旧文件，新文件改名进来时目录会再变一次。
    @discardableResult
    private func removeIfStale(_ name: String) -> Bool {
        guard let pid = SocketDirectory.pid(fromSocketName: name + ".sock"), SocketDirectory.processIsDead(pid) else { return false }
        return unlink(socketPath(name)) == 0
    }

    private func consume(_ link: PiConnection, name: String) async {
        for await line in link.connection.lines {
            guard links[name] === link else { return }
            // 读不懂的扩展：之后的消息格式不可知，只认告别（重载的告别要认得出，`SessionEndReason.reload`），等连接断开
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

    private func handle(_ message: PiWire.Message, on link: PiConnection, name: String) throws {
        guard let bridge else { return }
        switch message {
        case .hello(let hello):
            guard link.id == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            guard hello.hosted else { throw HandlingError.notHosted }
            guard let work = hello.state.work else { throw HandlingError.unknownState(hello.state.kind) }
            var session = Session(
                id: name, sessionID: hello.sessionId, agent: .pi, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid,
                cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory), state: work.state, detail: work.detail,
                errorMessage: hello.state.errorMessage, stateSince: hello.state.sinceDate, busySince: hello.state.busySinceDate)
            session.turnStartedAt = hello.state.turnSinceDate
            hello.info.apply(to: &session)
            session.launchToken = hello.launchToken
            link.extensionVersion = hello.extensionVersion
            appear(session, on: link)
            link.offerUpgrade()
        case .upgrading(let hello):
            guard link.id == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            guard hello.hosted else { throw HandlingError.notHosted }
            var session = Session(
                id: name, sessionID: hello.sessionId, agent: .pi, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid, cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory),
                state: .settled, upgrading: true, stateSince: Date())
            session.name = hello.name
            session.firstMessage = hello.firstMessage
            link.extensionVersion = hello.extensionVersion
            appear(session, on: link)
            link.offerUpgrade()
        case .state(let wire):
            guard let id = link.id else { throw HandlingError.messageBeforeHello }
            guard let work = wire.work else { throw HandlingError.unknownState(wire.kind) }
            bridge.update(id) { session in
                session.state = work.state
                session.detail = work.detail
                session.errorMessage = wire.errorMessage
                session.stateSince = wire.sinceDate
                session.busySince = wire.busySinceDate
                session.turnStartedAt = wire.turnSinceDate
            }
        case .info(let info):
            guard let id = link.id else { throw HandlingError.messageBeforeHello }
            bridge.update(id) { info.apply(to: &$0) }
        case .ack(let ack):
            if let id = ack.id { link.replies.resolve(id, with: .success(ack)) }
        case .bye(let bye):
            link.bye = bye
        case .draft(let draft):
            guard let session = link.session else { throw HandlingError.messageBeforeHello }
            bridge.setDraft(session.id, draft)
        case .quota(let report):
            guard link.id != nil else { throw HandlingError.messageBeforeHello }
            bridge.emit(.quota(report))
        }
    }

    private enum HandlingError: Error {
        case duplicateHello, nameMismatch, unknownState(String), messageBeforeHello
        /// 旧版装进 Pi 扩展目录的那份在终端里开的 pi 里也加载、也来连：CuePad 只管它托管的会话
        case notHosted
    }

    private func appear(_ session: Session, on link: PiConnection) {
        link.id = session.id
        link.exitWatcher = ProcessExitWatcher(pid: session.pid) { [weak self] in self?.processExited(session.id) }
        bridge?.attach(session, via: link)
    }

    /// 会话若已出现，随后走正常的结束路径。
    private func reject(_ link: PiConnection, name: String, detail: String) {
        link.rejected = true
        incompatible[name] = link.file
        bridge?.emit(.incompatible(id: name, detail: detail))
        link.connection.close()
    }

    /// 正常退出时扩展自己已删。
    private func processExited(_ name: String) {
        let path = socketPath(name)
        if SocketDirectory.isOwnSocket(path) { unlink(path) }
        orphanExitWatchers.removeValue(forKey: name)?.cancel()
    }

    private func finish(_ link: PiConnection, name: String) {
        guard links[name] === link else { return }
        links[name] = nil
        link.replies.closeAll(BridgeError.sessionEnded)
        // 没有告别就断开 = 进程被强杀，socket 文件会残留：进程已确认退出就现在删，否则等它的退出通知
        if link.bye == nil, link.id != nil, !removeIfStale(name), let watcher = link.exitWatcher {
            orphanExitWatchers[name] = watcher
        } else {
            link.exitWatcher?.cancel()
        }
        if let id = link.id {
            bridge?.detach(id, reason: link.bye.map { .closed(reason: $0.reason) } ?? .disconnected)
        }
        // /reload：同一进程在同一路径重新 listen。新文件的目录事件可能在这条连接还挂着时就被扫过（扫描跳过有连接的名字），
        // 之后不会再有事件，所以收尾时文件还在就当场连一次；还是旧文件（扩展还没删）时连不上，新文件的事件随后会到
        if FileManager.default.fileExists(atPath: socketPath(name)) { connect(name) }
    }
}
#endif
