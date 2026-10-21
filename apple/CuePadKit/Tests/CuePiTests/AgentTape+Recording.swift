#if os(macOS)
import CueStore
import CryptoKit
import CueTestSupport
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CuePi

extension AgentTape {
    func record(_ event: TapeEvent) {
        state.withLock { state in
            Self.snapshot(&state)
            var event = event
            event.d = event.d.map { event.b == true ? $0 : Self.normalize($0, &state) }
            event.p = event.p.map { Self.normalize($0, &state) }
            event.a = event.a?.map { Self.normalize($0, &state) }
            state.events.append(event)
        }
    }

    /// 录制时 Agent 说出的话交给 CuePad 之前：真进程的 pid 换成替身的（CuePad 只认得替身），真 Agent 用的 socket 目录换成 CuePad 的。
    func rewriteForCuePad(_ text: String) -> String {
        let (pids, outer) = state.withLock { ($0.realToStub, $0.outerSockets) }
        var text = text
        if let outer { text = text.replacing(inner.path, with: outer) }
        for (real, stub) in pids { text = Self.replaceNumber(real, with: String(stub), in: text) }
        return text
    }

    /// 盯着的目录里，自上次以来 Agent 写出的文件（新文件整份，已有文件只追加新的完整行）。不录删除：用例收尾时删临时目录早于
    /// 收尾的输入被录下，回放时会提前删掉；Agent 自己删的文件（假模型取走的放行标记）CuePad 不读。
    static func snapshot(_ state: inout State) {
        for root in state.watched {
            var info = stat()
            let paths: AnySequence<String> = lstat(root, &info) == 0 && info.st_mode & S_IFMT == S_IFREG
                ? AnySequence([root])
                : AnySequence((FileManager.default.enumerator(atPath: root)?.allObjects as? [String] ?? []).lazy.map { root + "/" + $0 })
            for path in paths {
                var info = stat()
                guard lstat(path, &info) == 0 else { continue }
                if info.st_mode & S_IFMT == S_IFDIR {
                    if state.files[path] == nil {
                        state.files[path] = FileShot(size: -1, modified: info.st_mtimespec, inode: info.st_ino, content: Data())
                        state.events.append(TapeEvent(k: "dir", p: normalize(path, &state)))
                    }
                    continue
                }
                guard info.st_mode & S_IFMT == S_IFREG else { continue }
                let old = state.files[path]
                if let old, old.size == Int(info.st_size), old.inode == info.st_ino, old.modified.tv_sec == info.st_mtimespec.tv_sec,
                   old.modified.tv_nsec == info.st_mtimespec.tv_nsec { continue }
                guard let data = FileManager.default.contents(atPath: path) else { continue }
                var shot = FileShot(size: Int(info.st_size), modified: info.st_mtimespec, inode: info.st_ino, content: data)
                if let old, old.size != -1, data.count >= old.content.count, data.prefix(old.content.count) == old.content {
                    var added = data.dropFirst(old.content.count)
                    guard let newline = added.lastIndex(of: 0x0A) else { shot.content = old.content; shot.size = -2; state.files[path] = shot; continue }
                    added = added[..<(newline + 1)]
                    shot.content = old.content + added
                    if shot.content.count != data.count { shot.size = -2 }
                    state.events.append(fileEvent(path, Data(added), append: true, &state))
                } else {
                    state.events.append(fileEvent(path, data, append: false, &state))
                }
                state.files[path] = shot
            }
        }
    }

    private static func fileEvent(_ path: String, _ data: Data, append: Bool, _ state: inout State) -> TapeEvent {
        let text = String(data: data, encoding: .utf8)
        return TapeEvent(k: "file", d: text.map { normalize($0, &state) } ?? data.base64EncodedString(), p: normalize(path, &state),
                         b: text == nil ? true : nil, ap: append ? true : nil)
    }

    /// 真 Agent 的 socket 目录（`i`）里：钩子 socket 由这里听着、转给 CuePad 的；扩展建的会话 socket 在 CuePad 的目录里建一个同名（pid 换成替身的）代理。
    func startHookProxy() throws {
        let fd = try UnixSocket.listen(inner.appending(path: "agent-hooks").path)
        hookSource = UnixSocket.accept(fd) { [self] client in
            Thread.detachNewThread { [self] in proxyHook(client) }
        }
        Thread.detachNewThread { [self] in watchInnerSockets() }
    }

    private func proxyHook(_ agentSide: Int32) {
        let reader = LineReader(fd: agentSide)
        guard let first = reader.next(), let outer = state.withLock({ $0.outerSockets }) else { close(agentSide); return }
        let path = outer + "/agent-hooks"
        let channel = state.withLock { state in state.hookCount += 1; return "h\(state.hookCount)" }
        let line = rewriteForCuePad(String(decoding: first, as: UTF8.self))
        record(TapeEvent(k: "hook", c: channel, d: Self.envelope(line, encoded: false), p: path))
        guard let cuepad = try? UnixSocket.connect(path) else {
            record(TapeEvent(k: "hangup", c: channel))
            close(agentSide); return
        }
        _ = UnixSocket.writeAll(cuepad, Data((line + "\n").utf8))
        pipe(from: reader, to: cuepad, channel: channel, kind: "close", agentToCuePad: true)
        pipe(from: LineReader(fd: cuepad), to: agentSide, channel: channel, kind: "hangup", agentToCuePad: false)
    }

    /// 一个方向的转发：一行一条录下再转过去；读到头时录下这一端关了，并关掉另一端的写。
    private func pipe(from reader: LineReader, to fd: Int32, channel: String, kind endKind: String, agentToCuePad: Bool) {
        Thread.detachNewThread { [self] in
            while let line = reader.next(partial: true) {
                var text = String(decoding: line, as: UTF8.self)
                if agentToCuePad { text = rewriteForCuePad(text) }
                record(TapeEvent(k: agentToCuePad ? "recv" : "send", c: channel, d: text))
                _ = UnixSocket.writeAll(fd, Data((text + "\n").utf8))
            }
            record(TapeEvent(k: endKind, c: channel))
            shutdown(fd, SHUT_WR)
        }
    }

    private func watchInnerSockets() {
        var known: [String: PiSocketDirectory.FileIdentity] = [:]
        var sources: [String: DispatchSourceRead] = [:]
        while !stopped.load(ordering: .relaxed) {
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: inner.path)) ?? []).filter { $0.hasSuffix(".sock") }
            for name in names {
                let path = inner.appending(path: name).path
                guard let identity = PiSocketDirectory.identity(of: path), PiSocketDirectory.isOwnSocket(path) else { continue }
                if let old = known[name], old == identity { continue }
                if known[name] != nil { unlisten(name, &known, &sources) }
                guard let outer = state.withLock({ $0.outerSockets }) else { continue }
                let outerPath = outer + "/" + rewriteForCuePad(name)
                let channel = state.withLock { state in
                    state.socketCount += 1
                    let channel = "s\(state.socketCount)"
                    state.socketChannels[name] = (channel, 0)
                    return channel
                }
                record(TapeEvent(k: "listen", c: channel, p: outerPath))
                guard let fd = try? UnixSocket.listen(outerPath, creatingDirectory: true) else { continue }
                known[name] = identity
                sources[name] = UnixSocket.accept(fd) { [self] client in
                    let connection = state.withLock { state in
                        state.socketChannels[name]!.connections += 1
                        return "\(channel).\(state.socketChannels[name]!.connections)"
                    }
                    record(TapeEvent(k: "connect", c: connection))
                    guard let agentSide = try? UnixSocket.connect(path) else {
                        record(TapeEvent(k: "close", c: connection))
                        close(client); return
                    }
                    pipe(from: LineReader(fd: client), to: agentSide, channel: connection, kind: "hangup", agentToCuePad: false)
                    pipe(from: LineReader(fd: agentSide), to: client, channel: connection, kind: "close", agentToCuePad: true)
                }
            }
            for name in known.keys where !names.contains(name) || PiSocketDirectory.identity(of: inner.appending(path: name).path) == nil {
                unlisten(name, &known, &sources)
            }
            usleep(5_000)
        }
        for source in sources.values { source.cancel() }
    }

    func unlisten(_ name: String, _ known: inout [String: PiSocketDirectory.FileIdentity], _ sources: inout [String: DispatchSourceRead]) {
        known[name] = nil
        sources.removeValue(forKey: name)?.cancel()
        let (channel, outer) = state.withLock { ($0.socketChannels[name]?.channel, $0.outerSockets) }
        guard let channel, let outer else { return }
        record(TapeEvent(k: "unlisten", c: channel))
        let path = outer + "/" + rewriteForCuePad(name)
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
    }
}
#endif
