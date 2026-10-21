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
    private func load() -> Bool {
        let file = file
        return state.withLock { state in
            if let replay = state.replay { return !replay.events.isEmpty }
            guard let data = FileManager.default.contents(atPath: file.path) else {
                state.problems.append("没有录制数据 \(file.path)：TEST_RUNNER_CUEPAD_AGENT_TESTS=\(state.agent?.rawValue ?? "?") apple/scripts/xc.sh test kit -only-testing:CuePiTests 录一遍")
                state.replay = Replay(events: [], matched: [])
                return false
            }
            var events = data.split(separator: 0x0A).compactMap { try? JSONDecoder().decode(TapeEvent.self, from: $0) }
            // 连上就断、一句没说的连接（桥在会话关掉的那一刻重连，赶上没赶上全看时机）：不等它，回放时多出来的也不算
            let talked = Set(events.filter { $0.k == "send" || $0.k == "recv" }.compactMap(\.c))
            events.removeAll { ["connect", "close", "hangup"].contains($0.k) && $0.c?.hasPrefix("s") == true && !talked.contains($0.c!) }
            // 没人叫它退、自己退出的（空闲到点、崩溃）：退出前多等一会，见 `barrier`
            var asked = Set<String>()
            for index in events.indices {
                let event = events[index]
                if ["signal", "eof", "gone"].contains(event.k), let channel = event.c { asked.insert(channel) }
                if event.k == "exit", let channel = event.c, !asked.contains(channel) { events[index].spontaneous = true }
            }
            state.replay = Replay(events: events, matched: Array(repeating: false, count: events.count))
            startEmitting()
            return true
        }
    }

    /// 一条输入到了：认领录像带里这条通道上最早没认领的同类输入，比对内容，再接着做出后面的输出。返回认领到的通道。
    @discardableResult
    func input(_ kind: String, channel: String, data: String? = nil) -> String? {
        claim(kind, where: { $0.c == channel }, data: data, recorded: { [$0.d ?? ""] }).map { found in
            advance()
            return found
        }
    }

    /// - Parameter attach: 认领到时在同一把锁里登记这条通道的替身或连接：之后的输出可能马上就要写给它。
    func claim(
        _ kind: String, where match: (TapeEvent) -> Bool, data: String?, recorded: (TapeEvent) -> [String],
        attach: (inout State, String) -> Void = { _, _ in }
    ) -> String? {
        guard load() else { return nil }
        return state.withLock { state -> String? in
            guard var replay = state.replay else { return nil }
            let candidates = replay.events.indices.filter { !replay.matched[$0] && replay.events[$0].k == kind && match(replay.events[$0]) }
            // 先认内容对得上的（同时起的几个进程、并发的几个请求，先后可以与录制时不同），都对不上再按先后
            let same = data.flatMap { data in
                candidates.prefix(32).first { index in
                    let expected = recorded(replay.events[index]).map { Self.expand($0, &state) }.joined(separator: "\u{1}")
                    let actual = data.replacing("\\/", with: "/")
                    var probe = replay
                    return expected == actual || TapeCompare.compare(expected: expected, actual: actual, into: &probe) == nil
                }
            }
            guard let index = same ?? candidates.first else {
                // 收尾时多出来的信号、断开（重复的 terminate、对已退出的进程发信号）不算
                if !["signal", "hangup", "eof", "gone", "connect"].contains(kind) {
                    state.problems.append("回放：录像带里没有这条输入 \(kind) \(data.map { String($0.prefix(300)) } ?? "")")
                }
                return nil
            }
            replay.matched[index] = true
            let event = replay.events[index]
            debugLine("in #\(index) \(event.k) \(event.c ?? "")", t0: state.t0)
            if let data {
                let expected = recorded(event).map { Self.expand($0, &state) }.joined(separator: "\u{1}")
                let actual = data.replacing("\\/", with: "/")
                if expected != actual, let problem = TapeCompare.compare(expected: expected, actual: actual, into: &replay) {
                    state.problems.append("回放：\(event.c ?? "") 的输入与录制不符（\(problem)），TEST_RUNNER_CUEPAD_AGENT_TESTS=\(state.agent?.rawValue ?? "?") 重录")
                }
            }
            state.replay = replay
            if let channel = event.c { attach(&state, channel) }
            return event.c
        }
    }

    /// 做出光标处起、前面输入都已到的输出（一条任务按录下的先后做）。
    func advance() {
        wakes.continuation.yield()
    }

    private func startEmitting() {
        emitting = Task.detached { [self] in
            var previous: TapeEvent?
            for await _ in wakes.stream {
                while let event = nextOutput() {
                    if let previous, Self.needsBarrier(from: previous, to: event) { await barrier(after: previous, before: event) }
                    perform(event)
                    if Self.readByCuePad.contains(event.k) { previous = event }
                }
            }
        }
    }

    private func nextOutput() -> TapeEvent? {
        state.withLock { state -> TapeEvent? in
            guard var replay = state.replay else { return nil }
            defer { state.replay = replay }
            while replay.cursor < replay.events.count {
                let event = replay.events[replay.cursor]
                if event.isInput {
                    guard replay.matched[replay.cursor] else { return nil }
                    replay.cursor += 1
                    continue
                }
                replay.cursor += 1
                var expanded = event
                expanded.d = event.d.map { event.b == true ? $0 : Self.substitute(Self.expand($0, &state), replay) }
                expanded.p = event.p.map { Self.substitute(Self.expand($0, &state), replay) }
                return expanded
            }
            return nil
        }
    }

    /// CuePad 经不同的通道读 Agent（标准输出、钩子、socket），各自异步处理；回放一口气写完时，后写的通道可能先被处理，
    /// 与录制时的先后相反。换通道前等前一条被读走（替身的标准输出读空）、主线程上排着的处理跑完。
    private static let readByCuePad: Set<String> = ["stdout", "stderr", "exit", "recv", "close", "hook"]

    private static func needsBarrier(from previous: TapeEvent, to next: TapeEvent) -> Bool {
        next.spontaneous == true || readByCuePad.contains(next.k) && previous.c != next.c
    }

    private func barrier(after previous: TapeEvent, before next: TapeEvent) async {
        if previous.k == "stdout" || previous.k == "stderr", let stub = state.withLock({ $0.stubs[previous.c ?? ""] }) {
            await stub.drained()
        }
        // 自己退出的进程（空闲到点）退出前多等一会：CuePad 往往还在处理它退出前说的最后几句（会话出现、告别），
        // 退出的通知（kqueue、waitpid）却很快——录制时两者之间隔着真实的时间
        let spontaneous = next.spontaneous == true
        for _ in 0..<(spontaneous ? 4 : 2) { await MainActor.run {} }
        try? await Task.sleep(for: .milliseconds(spontaneous ? 100 : 1))
    }

    private func perform(_ event: TapeEvent) {
        let channel = event.c ?? ""
        debug("out \(event.k) \(channel)")
        switch event.k {
        case "stdout", "stderr":
            state.withLock { $0.stubs[channel] }?.send((event.k == "stdout" ? "o " : "r ") + Data(((event.d ?? "") + "\n").utf8).base64EncodedString())
        case "exit":
            guard let stub = state.withLock({ $0.stubs[channel] }) else { return }
            stub.told = true
            let code = event.n ?? 0
            stub.send(code < 0 ? "k \(-code)" : "x \(code)")
        case "listen":
            guard let path = event.p, let fd = try? UnixSocket.listen(path, creatingDirectory: true) else { return }
            let source = UnixSocket.accept(fd) { [self] client in
                let connection = Connection(fd: client)
                guard let claimed = claim("connect", where: { $0.c?.hasPrefix(channel + ".") == true }, data: nil, recorded: { _ in [] },
                                          attach: { $0.connections[$1] = connection }) else {
                    close(client); return
                }
                serve(connection, as: claimed)
            }
            state.withLock { $0.listeners[channel] = (source, path) }
        case "unlisten":
            // 录下的 unlisten 就是 socket 文件没了（扩展正常退出时自己删）
            guard let listener = state.withLock({ $0.listeners.removeValue(forKey: channel) }) else { return }
            listener.source.cancel()
            unlink(listener.path)
        case "recv":
            state.withLock { $0.connections[channel] }?.write((event.d ?? "") + "\n")
        case "close":
            state.withLock { $0.connections.removeValue(forKey: channel) }?.close()
        case "hook":
            guard let path = event.p, let fd = try? UnixSocket.connect(path) else { return }
            let connection = Connection(fd: fd)
            connection.write(Self.envelope(event.d ?? "", encoded: true) + "\n")
            serve(connection, as: channel)
        case "file":
            guard let path = event.p else { return }
            let data = event.b == true ? Data(base64Encoded: event.d ?? "") ?? Data() : Data((event.d ?? "").utf8)
            try? FileManager.default.createDirectory(at: URL(filePath: path).deletingLastPathComponent(), withIntermediateDirectories: true)
            if event.ap == true, let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        case "dir":
            if let path = event.p { try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true) }
        default: break
        }
    }

    /// 回放时 CuePad 那一端的一条连接：它写来的一行一条当作输入，关了也是。
    private func serve(_ connection: Connection, as channel: String) {
        state.withLock { $0.connections[channel] = connection }
        advance()
        Thread.detachNewThread { [self] in
            let reader = LineReader(fd: connection.fd)
            while let line = reader.next(partial: true) { input("send", channel: channel, data: String(decoding: line, as: UTF8.self)) }
            input("hangup", channel: channel)
        }
    }
}
#endif
