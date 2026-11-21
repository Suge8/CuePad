#if os(macOS)
import CueStore
import Darwin
import Foundation
import os

@MainActor
final class PiConnections {
    private static let log = Logger(subsystem: AppIdentity.id, category: "bridge")
    private let directory: URL
    weak var bridge: Bridge?
    private var links: [String: PiConnection] = [:]
    private var watcher: DirectoryWatcher?
    private var rewatching: Task<Void, Never>?
    private let timing: Timing
    private var orphanExitWatchers: [String: ProcessExitWatcher] = [:]
    private var incompatible: [String: SocketDirectory.FileIdentity] = [:]

    init(directory: URL, timing: Timing) {
        self.directory = directory
        self.timing = timing
    }

    func start() throws {
        guard watcher == nil, rewatching == nil else { return }
        try watch()
    }

    private func watch() throws {
        try SocketDirectory.prepare(directory)
        watcher = try DirectoryWatcher(directory) { [weak self] gone in self?.directoryChanged(gone: gone) }
        scan()
    }

    /// 目录在 /tmp 下，系统每天清一次（`/usr/libexec/tmp_cleaner`）：空着超过 3 天的目录会被删，扩展起来时再建的是另一个目录，得改盯它。
    /// 已连上的会话不受影响（连接不靠目录）。重建一时不成（路径被别的东西占着、权限不对）就退避重试到盯上为止，同 OpenCode 事件流的重连。
    private func directoryChanged(gone: Bool) {
        guard gone else { return scan() }
        watcher?.cancel()
        watcher = nil
        rewatching?.cancel()
        let timing = timing
        rewatching = Task { [weak self] in
            var delay = Self.retryFloor
            while !Task.isCancelled, let self {
                do {
                    try self.watch()
                    self.rewatching = nil
                    return
                } catch {
                    Self.log.error("socket directory removed and not recreated yet, new Pi sessions cannot connect; retrying in \(delay, privacy: .public): \(String(describing: error), privacy: .public)")
                }
                guard (try? await timing.sleep(delay)) != nil else { return }
                delay = min(delay * 2, Self.retryCeiling)
            }
        }
    }

    private static let retryFloor: Duration = .seconds(1)
    private static let retryCeiling: Duration = .seconds(30)

    func stop() {
        watcher?.cancel()
        watcher = nil
        rewatching?.cancel()
        rewatching = nil
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
        } catch {
            incompatible[name] = file
            Self.log.error("\(name, privacy: .public) cannot connect: \(String(describing: error), privacy: .public)")
        }
    }

    @discardableResult
    private func removeIfStale(_ name: String) -> Bool {
        guard let pid = SocketDirectory.pid(fromSocketName: name + ".sock"), SocketDirectory.processIsDead(pid) else { return false }
        return unlink(socketPath(name)) == 0
    }

    private func consume(_ link: PiConnection, name: String) async {
        for await line in link.connection.lines {
            guard links[name] === link else { return }
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
            guard let work = hello.state.work else { throw HandlingError.unknownState(hello.state.kind) }
            var session = Session(
                id: name, sessionID: hello.sessionId, agent: .pi, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid,
                cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory), state: work.state, detail: work.detail,
                errorMessage: hello.state.errorMessage, stateSince: hello.state.sinceDate, busySince: hello.state.busySinceDate)
            session.turnStartedAt = hello.state.turnSinceDate
            session.turnOpener = hello.state.turnOpener
            hello.info.apply(to: &session)
            session.launchToken = hello.launchToken
            appear(session, on: link)
            link.offerUpgrade(from: hello.extensionVersion)
        case .upgrading(let hello):
            guard link.id == nil else { throw HandlingError.duplicateHello }
            guard "\(hello.sessionId).\(hello.pid)" == name else { throw HandlingError.nameMismatch }
            var session = Session(
                id: name, sessionID: hello.sessionId, agent: .pi, sessionFile: hello.sessionFile.map { URL(filePath: $0) }, pid: hello.pid, cwd: URL(filePath: hello.cwd, directoryHint: .isDirectory),
                state: .settled, upgrading: true, stateSince: Date())
            session.name = hello.name
            session.firstMessage = hello.firstMessage
            appear(session, on: link)
            link.offerUpgrade(from: hello.extensionVersion)
        case .state(let wire):
            guard let id = link.id else { throw HandlingError.messageBeforeHello }
            guard let work = wire.work else { throw HandlingError.unknownState(wire.kind) }
            bridge.update(id) { session in
                session.stateSince = wire.sinceDate
                session.busySince = wire.busySinceDate
                session.state = work.state
                session.detail = work.detail
                session.errorMessage = wire.errorMessage
                session.turnStartedAt = wire.turnSinceDate
                session.turnOpener = wire.turnOpener
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
    }

    private func appear(_ session: Session, on link: PiConnection) {
        link.id = session.id
        link.exitWatcher = ProcessExitWatcher(pid: session.pid) { [weak self] in self?.processExited(session.id) }
        bridge?.attach(session, via: link)
    }

    private func reject(_ link: PiConnection, name: String, detail: String) {
        link.rejected = true
        incompatible[name] = link.file
        Self.log.error("\(name, privacy: .public) incompatible: \(detail, privacy: .public)")
        link.connection.close()
    }

    private func processExited(_ name: String) {
        let path = socketPath(name)
        if SocketDirectory.isOwnSocket(path) { unlink(path) }
        orphanExitWatchers.removeValue(forKey: name)?.cancel()
    }

    private func finish(_ link: PiConnection, name: String) {
        guard links[name] === link else { return }
        links[name] = nil
        link.replies.closeAll(BridgeError.sessionEnded)
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
