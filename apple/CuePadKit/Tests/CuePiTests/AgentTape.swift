#if os(macOS)
import CueStore
import CryptoKit
import CueTestSupport
import Darwin
import Foundation
import Synchronization
import Testing
@testable import CuePi

/// 真 Agent 用例的录像带：CuePad 读 Agent 输出的那些边界——Agent 进程的标准输入输出、信号与退出（经替身进程 `Fixtures/tape-stub.c`）、
/// Pi 扩展的 socket、钩子 socket、Agent 写出的文件——录制时接在真 Agent 上并逐条记下，回放时按录下的先后原样做出来，产品代码走同一条路。
///
/// 先后的规则：回放时一条输出在它之前录下的输入全都到了才做出来（输入按各自的通道排队认领，跨通道的先后可以不同）；
/// 输入（CuePad 或测试发给 Agent 的）与录下的逐项比对，随机 id（UUID）与时间不算不同，其余不同记为问题：录像带跟不上用例，重录。
/// 录下的文本里，临时目录、家目录、产物目录、pid、时间都换成占位符（回放时换回此刻的值），密钥与邮箱抹掉。
final class AgentTape: @unchecked Sendable {
    @TaskLocal static var current: AgentTape?

    /// 当前用例的录像带（用例的套件要带 `.agentTape(_:)`）。
    static var active: AgentTape {
        guard let current else { fatalError("这个用例没有录像带：套件上加 .agentTape(<家>)") }
        return current
    }

    private let baseName: String
    /// 录像带自己的目录：替身（`bin`）、替身连回来的 socket、录制时真 Agent 用的 socket 目录（`i`）
    let directory: URL
    var bin: URL { directory.appending(path: "bin", directoryHint: .isDirectory) }
    private var control: String { directory.appending(path: "t.sock").path }
    private var inner: URL { directory.appending(path: "i", directoryHint: .isDirectory) }
    private let state: Mutex<State>
    /// 回放：有新的输入到了就叫醒做输出的那条任务
    private let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    private var emitting: Task<Void, Never>?
    private var controlSource: DispatchSourceRead?
    private let stopped = Atomic(false)

    /// 编译好的替身（`Fixtures/tape-stub.c`）：按源码的哈希缓存在临时目录，本机第一次用时编译一次。
    private static let stub: Result<URL, any Error> = Result {
        let source = fixturesDirectory.appending(path: "tape-stub.c")
        let hash = SHA256.hash(data: try Data(contentsOf: source)).prefix(8).map { String(format: "%02x", $0) }.joined()
        let binary = URL(filePath: NSTemporaryDirectory()).appending(path: "cuepad-tape-stub-\(hash)")
        if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
        let building = binary.appendingPathExtension("\(getpid())")
        let cc = Process()
        cc.executableURL = URL(filePath: "/usr/bin/cc")
        cc.arguments = ["-O2", "-o", building.path, source.path]
        guard try ProcessExit(launching: cc).blockingValue == 0 else { throw CocoaError(.executableLoad, userInfo: [NSFilePathErrorKey: source.path]) }
        _ = rename(building.path, binary.path)
        return binary
    }

    /// 替身的名字 → 录制时背后的真 Agent
    static let realExecutables: [String: URL?] = ["pi": realPiURL, "codex": realCodexURL, "claude": claudeURL]

    /// - Parameter agent: 一个套件一家时由特征给出；几家共用一个套件时用例自己用 `use(_:variant:)` 给出。
    init(agent: AgentKind?, test: Test) throws {
        let suite = test.id.nameComponents.dropLast().last ?? "Suite"
        let function = test.name.split(separator: "(").first.map(String.init) ?? test.name
        baseName = "\(suite)/\(function)"
        directory = try makeTempDirectory()
        let root = directory.deletingLastPathComponent().path
        state = Mutex(State(t0: Date().timeIntervalSince1970 * 1000, temporaryRoot: root,
                            temporaryDirectories: [Int(directory.lastPathComponent)!], agent: agent))
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let stub = try Self.stub.get()
        for name in Self.realExecutables.keys { try FileManager.default.createSymbolicLink(at: bin.appending(path: name), withDestinationURL: stub) }
        try startControl()
    }

    var agent: AgentKind? { state.withLock { $0.agent } }
    /// 列出这家是录制，否则回放；OpenCode 没有录像带，列出时直接连真的（`live`）。
    var mode: TapeMode { agent.map(RealAgents.mode(of:)) ?? .replay }

    // MARK: 用例的接口

    /// 参数化用例的每组参数各用一盘：在用例开头、起任何进程之前给出这组参数的名字。
    static func variant(_ name: String) {
        active.state.withLock { $0.variant = name }
    }

    /// 几家共用一个套件时：这个用例录哪一家（与参数的名字）。
    static func use(_ agent: AgentKind, variant: String? = nil) {
        active.state.withLock { state in
            state.agent = agent
            state.variant = variant
        }
    }

    /// 测试驱动起的进程带上它（逗号分隔的事件类型）：录像带只录标准输出里这几类事件。
    static let stdoutTypesVariable = "CUEPAD_TAPE_STDOUT_TYPES"

    private static func type(of line: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["type"] as? String
    }

    /// 这家在录像带里的替身（交给 CuePad 当可执行文件，或放进它的查找目录）；直接连真 Agent 时是真的。
    func executable(_ name: String) -> URL {
        mode == .live ? (Self.realExecutables[name] ?? nil) ?? bin.appending(path: name) : bin.appending(path: name)
    }

    /// 当前用例里这家的可执行文件：有录像带用替身，没有录像带（只连真 Agent）的用例用真的。
    static func executable(_ name: String) -> URL { current?.executable(name) ?? (realExecutables[name] ?? nil)! }
    static func locator(_ name: String) -> ExecutableLocator { ExecutableLocator(searchDirectories: [executable(name).deletingLastPathComponent()]) }

    /// 录制时盯着这些目录里 Agent 写出的文件（会话文件、工作目录里的产物）。
    func watch(_ urls: URL...) {
        guard mode == .record else { return }
        state.withLock { $0.watched += urls.map(\.path) }
    }

    /// 测试经文件系统等旁路交给 Agent 的动作（如放行假模型）：录制时记下，回放时当作这一步输入已到。
    func mark(_ name: String) {
        switch mode {
        case .record: record(TapeEvent(k: "mark", c: "mark", d: name))
        case .replay: input("mark", channel: "mark", data: name)
        case .live: break
        }
    }

    /// 录制时不能进录像带的值（密钥、令牌）。
    func secret(_ values: String?...) {
        state.withLock { $0.secrets += values.compactMap { $0 }.filter { $0.count >= 8 } }
    }

    /// 登录文件里的每个字符串值都是机密。
    func secret(tokens object: Any) {
        switch object {
        case let dictionary as [String: Any]: dictionary.values.forEach { secret(tokens: $0) }
        case let string as String:
            secret(string)
            // JWT 里的邮箱
            for part in string.split(separator: ".") {
                var base64 = String(part).replacing("-", with: "+").replacing("_", with: "/")
                base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
                if let data = Data(base64Encoded: base64), let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   let email = claims["email"] as? String {
                    state.withLock { $0.secrets.append(email) }
                }
            }
        default: break
        }
    }

    /// makeTempDirectory 建的目录：录下的路径按建出的先后换成占位符。
    func register(temporaryDirectory url: URL) {
        guard let number = Int(url.lastPathComponent) else { return }
        state.withLock { $0.temporaryDirectories.append(number) }
    }

    private var file: URL {
        let (agent, variant) = state.withLock { ($0.agent, $0.variant) }
        return fixturesDirectory.appending(path: "tapes/\(agent?.rawValue ?? "?")/\(baseName)\(variant.map { " \($0)" } ?? "").jsonl")
    }

    // MARK: 收尾

    /// `keep`：用例没抛错。录制时只在这时写下这一盘（真 Agent 出错、额度用完时原来那盘留着）。
    func finish(keep: Bool = true) async {
        stopped.store(true, ordering: .relaxed)
        controlSource?.cancel()
        hookSource?.cancel()
        switch mode {
        case .live:
            break
        case .record:
            let pids = state.withLock { $0.realGroups }
            for pid in pids { killpg(pid, SIGTERM) }
            for pid in pids { try? await eventually("真 Agent 进程组 \(pid) 退出", timeout: .seconds(5)) { killpg(pid, 0) != 0 } }
            for pid in pids { killpg(pid, SIGKILL) }
            guard keep else { return }
            let events = state.withLock { state in
                Self.snapshot(&state)
                return state.events
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let text = events.map { String(decoding: try! encoder.encode($0), as: UTF8.self) }.joined(separator: "\n") + "\n"
            do {
                if events.isEmpty {  // 没碰 Agent 的用例不留空录像带
                    try? FileManager.default.removeItem(at: file)
                    return
                }
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                Issue.record("写录像带失败：\(error)")
            }
        case .replay:
            let (stubs, problems, next) = state.withLock { state in
                (Array(state.stubs.values), state.problems, state.replay.flatMap { $0.firstUnmatchedInput })
            }
            for stub in stubs where !stub.told { stub.send("x 0") }
            emitting?.cancel()
            wakes.continuation.finish()
            await emitting?.value
            state.withLock { state in
                for listener in state.listeners.values { listener.source.cancel() }
                for connection in state.connections.values { connection.close() }
            }
            for problem in problems { Issue.record(Comment(rawValue: problem)) }
            // 只在用例出错时报停在哪一步：通过的用例收尾早于录像带末尾是常态
            if let next, !keep || !problems.isEmpty { print("录像带 \(file.lastPathComponent)：回放停在 #\(next.index) \(next.event.k) \(next.event.c ?? "")") }
        }
    }

    // MARK: 状态

    fileprivate struct State {
        var t0: Double
        var temporaryRoot: String
        var temporaryDirectories: [Int]
        var agent: AgentKind?
        var variant: String?
        var proxying = false
        var secrets: [String] = []
        var watched: [String] = []
        var problems: [String] = []
        // 录制
        var events: [TapeEvent] = []
        var files: [String: FileShot] = [:]
        var processCount = 0
        var socketCount = 0
        var hookCount = 0
        var socketChannels: [String: (channel: String, connections: Int)] = [:]
        var realToStub: [Int32: Int32] = [:]
        var realGroups: [Int32] = []
        var outerSockets: String?
        // 两种模式都用：替身与连接
        var stubPids: [String: Int32] = [:]
        var stubs: [String: Stub] = [:]
        var connections: [String: Connection] = [:]
        /// 回放时 listen 着的 socket：通道 → 事件源与路径
        var listeners: [String: (source: DispatchSourceRead, path: String)] = [:]
        // 回放
        var replay: Replay?
    }

    fileprivate struct FileShot {
        var size: Int
        var modified: timespec
        var inode: ino_t
        /// 已经录下的内容（追加时只录新的完整行）
        var content: Data
    }

    fileprivate struct Replay {
        var events: [TapeEvent]
        var matched: [Bool]
        var cursor = 0
        var substitutions: [String: String] = [:]
        var ids: [Int: Int] = [:]

        var firstUnmatchedInput: (index: Int, event: TapeEvent)? {
            events.indices.first { events[$0].isInput && !matched[$0] }.map { ($0, events[$0]) }
        }
    }

    // MARK: 录制

    private func record(_ event: TapeEvent) {
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
    private func rewriteForCuePad(_ text: String) -> String {
        let (pids, outer) = state.withLock { ($0.realToStub, $0.outerSockets) }
        var text = text
        if let outer { text = text.replacing(inner.path, with: outer) }
        for (real, stub) in pids { text = Self.replaceNumber(real, with: String(stub), in: text) }
        return text
    }

    /// 盯着的目录里，自上次以来 Agent 写出的文件（新文件整份，已有文件只追加新的完整行）。不录删除：用例收尾时删临时目录早于
    /// 收尾的输入被录下，回放时会提前删掉；Agent 自己删的文件（假模型取走的放行标记）CuePad 不读。
    fileprivate static func snapshot(_ state: inout State) {
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

    // MARK: 替身

    private func startControl() throws {
        let fd = try UnixSocket.listen(control)
        controlSource = UnixSocket.accept(fd) { [self] client in
            Thread.detachNewThread { [self] in serveStub(client) }
        }
    }

    /// 一个替身连上来：读它的命令行与环境，录制时起真 Agent 接上，回放时认领录像带里的这次启动。
    private func serveStub(_ fd: Int32) {
        let reader = LineReader(fd: fd)
        var name = "", pid: Int32 = 0, cwd = "", arguments: [String] = [], environment: [String: String] = [:]
        header: while let line = reader.next() {
            let (kind, value) = Self.split(line)
            let decoded = String(decoding: Data(base64Encoded: value) ?? Data(), as: UTF8.self)
            switch kind {
            case "n": name = decoded
            case "p": pid = Int32(value) ?? 0
            case "w": cwd = decoded
            case "a": arguments.append(decoded)
            case "v": if let eq = decoded.firstIndex(of: "=") { environment[String(decoded[..<eq])] = String(decoded[decoded.index(after: eq)...]) }
            case "h": break header
            default: break
            }
        }
        let stub = Stub(fd: fd, pid: pid)
        switch mode {
        case .record, .live: recordProcess(stub, reader, name: name, arguments: arguments, cwd: cwd, environment: environment)
        case .replay: replayProcess(stub, reader, name: name, arguments: arguments, cwd: cwd, mark: environment[HostMark.variable])
        }
    }

    private func recordProcess(_ stub: Stub, _ reader: LineReader, name: String, arguments: [String], cwd: String, environment: [String: String]) {
        guard let real = Self.realExecutables[name] ?? nil else {
            stub.send("r " + Data("录像带：没有真的 \(name)\n".utf8).base64EncodedString())
            return stub.send("x 127")
        }
        if !state.withLock({ state in defer { state.proxying = true }; return state.proxying }) {
            try? FileManager.default.createDirectory(at: inner, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try? startHookProxy()
        }
        var environment = environment
        let channel = state.withLock { state in
            state.processCount += 1
            state.secrets += environment.filter { key, value in
                ["KEY", "TOKEN", "SECRET", "PASSWORD"].contains { key.uppercased().contains($0) } && value.count >= 8
            }.map(\.value)
            if let outer = environment["CUEPAD_PI_SOCKET_DIR"] { state.outerSockets = outer }
            return "p\(state.processCount)"
        }
        if let outer = environment["CUEPAD_PI_SOCKET_DIR"] {
            var info = stat()
            chmod(inner.path, lstat(outer, &info) == 0 ? info.st_mode & 0o777 : 0o700)
            environment["CUEPAD_PI_SOCKET_DIR"] = inner.path
        }
        environment["PATH"] = ((environment["PATH"] ?? "").split(separator: ":").map(String.init).filter { $0 != bin.path }
            + [real.deletingLastPathComponent().path]).joined(separator: ":")
        record(TapeEvent(k: "spawn", c: channel, d: name, p: cwd, a: arguments, m: environment[HostMark.variable]))
        /// 只有测试读它的标准输出、且只读这几类事件（`PiProcess`）：别的行照样交出去，不录
        let kept = environment.removeValue(forKey: Self.stdoutTypesVariable).map { Set($0.split(separator: ",").map(String.init)) }
        guard let process = try? RealProcess(real, arguments, cwd: cwd, environment: environment) else {
            record(TapeEvent(k: "exit", c: channel, n: 127))
            return stub.send("x 127")
        }
        state.withLock { state in
            state.realToStub[process.pid] = stub.pid
            state.stubPids[channel] = stub.pid
            state.realGroups.append(process.pid)
            state.stubs[channel] = stub
        }
        let outputs = DispatchGroup()
        for (fd, kind, prefix) in [(process.stdout, "stdout", "o"), (process.stderr, "stderr", "r")] {
            outputs.enter()
            Thread.detachNewThread { [self] in
                var lines = LineSplitter()
                func forward(_ line: Data, newline: Bool) {
                    let text = rewriteForCuePad(String(decoding: line, as: UTF8.self))
                    if kind == "stderr" || kept.map({ Self.type(of: text).map($0.contains) ?? false }) ?? true {
                        record(TapeEvent(k: kind, c: channel, d: text))
                    }
                    stub.send(prefix + " " + Data((text + (newline ? "\n" : "")).utf8).base64EncodedString())
                }
                UnixSocket.read(fd) { chunk in for line in lines.append(chunk) { forward(line, newline: true) } }
                if let rest = lines.flush() { forward(rest, newline: false) }
                close(fd)
                outputs.leave()
            }
        }
        Thread.detachNewThread { [self] in
            let status = process.wait()
            _ = outputs.wait(timeout: .now() + 2)
            let signaled = status & 0x7F != 0
            let code = signaled ? -Int(status & 0x7F) : Int((status >> 8) & 0xFF)
            record(TapeEvent(k: "exit", c: channel, n: code))
            stub.told = true
            stub.send(signaled ? "k \(-code)" : "x \(code)")
        }
        var lines = LineSplitter()
        while let line = reader.next() {
            let (kind, value) = Self.split(line)
            switch kind {
            case "i":
                let data = Data(base64Encoded: value) ?? Data()
                for line in lines.append(data) { record(TapeEvent(k: "stdin", c: channel, d: String(decoding: line, as: UTF8.self))) }
                _ = UnixSocket.writeAll(process.stdin, data)
            case "e":
                if let rest = lines.flush() { record(TapeEvent(k: "stdin", c: channel, d: String(decoding: rest, as: UTF8.self))) }
                record(TapeEvent(k: "eof", c: channel))
                process.closeInput()
            case "s":
                record(TapeEvent(k: "signal", c: channel, n: Int(value) ?? 0))
                kill(process.pid, Int32(value) ?? SIGTERM)
            default: break
            }
        }
        if !stub.told {
            record(TapeEvent(k: "gone", c: channel))
            killpg(process.pid, SIGKILL)
        }
    }

    /// `mark`：CuePad 给托管进程的标记（`HostMark`，每次一个新的 UUID）。一并比对，回放时录下的钩子环境里那个才换成这次的。
    private func replayProcess(_ stub: Stub, _ reader: LineReader, name: String, arguments: [String], cwd: String, mark: String?) {
        guard let channel = claim("spawn", where: { $0.d == name }, data: ([cwd] + arguments + [mark ?? ""]).joined(separator: "\u{1}"),
                                  recorded: { [$0.p ?? ""] + ($0.a ?? []) + [$0.m ?? ""] },
                                  attach: { state, channel in
                                      state.stubPids[channel] = stub.pid
                                      state.stubs[channel] = stub
                                  }) else {
            stub.send("r " + Data("录像带里没有这次启动：\(name) \(arguments.joined(separator: " "))\n".utf8).base64EncodedString())
            return stub.send("x 127")
        }
        advance()
        var lines = LineSplitter()
        while let line = reader.next() {
            let (kind, value) = Self.split(line)
            switch kind {
            case "i": for line in lines.append(Data(base64Encoded: value) ?? Data()) { input("stdin", channel: channel, data: String(decoding: line, as: UTF8.self)) }
            case "e":
                if let rest = lines.flush() { input("stdin", channel: channel, data: String(decoding: rest, as: UTF8.self)) }
                input("eof", channel: channel)
            case "s": input("signal", channel: channel)
            case "f": stub.acknowledged()
            default: break
            }
        }
        stub.acknowledged(gone: true)
        if !stub.told { input("gone", channel: channel) }
    }

    // MARK: socket 代理（录制）

    private var hookSource: DispatchSourceRead?
    private var socketWatch: Task<Void, Never>?

    /// 真 Agent 的 socket 目录（`i`）里：钩子 socket 由这里听着、转给 CuePad 的；扩展建的会话 socket 在 CuePad 的目录里建一个同名（pid 换成替身的）代理。
    private func startHookProxy() throws {
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

    private func unlisten(_ name: String, _ known: inout [String: PiSocketDirectory.FileIdentity], _ sources: inout [String: DispatchSourceRead]) {
        known[name] = nil
        sources.removeValue(forKey: name)?.cancel()
        let (channel, outer) = state.withLock { ($0.socketChannels[name]?.channel, $0.outerSockets) }
        guard let channel, let outer else { return }
        record(TapeEvent(k: "unlisten", c: channel))
        let path = outer + "/" + rewriteForCuePad(name)
        var info = stat()
        if lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFSOCK { unlink(path) }
    }

    // MARK: 回放

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
    private func input(_ kind: String, channel: String, data: String? = nil) -> String? {
        claim(kind, where: { $0.c == channel }, data: data, recorded: { [$0.d ?? ""] }).map { found in
            advance()
            return found
        }
    }

    /// - Parameter attach: 认领到时在同一把锁里登记这条通道的替身或连接：之后的输出可能马上就要写给它。
    private func claim(
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
    private func advance() {
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

    // MARK: 文本

    private func debug(_ text: String) { debugLine(text, t0: state.withLock { $0.t0 }) }
    private func debugLine(_ text: String, t0: Double) {
        guard let filter = ProcessInfo.processInfo.environment["TAPE_DEBUG"], baseName.contains(filter) else { return }
        FileHandle.standardError.write(Data("TAPE \(Int(Date().timeIntervalSince1970 * 1000 - t0)) \(text)\n".utf8))
    }

    /// 钩子信封里 Agent 写给钩子的输入是 base64（`AgentHookEnvelope.input`）：录下时解开成文本（`inputText`），里面的路径、时间才归一得了；回放时再编回去。
    private static func envelope(_ line: String, encoded: Bool) -> String {
        guard var object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else { return line }
        if encoded, let text = object.removeValue(forKey: "inputText") as? String {
            object["input"] = Data(text.utf8).base64EncodedString()
        } else if !encoded, let input = object["input"] as? String, let data = Data(base64Encoded: input), let text = String(data: data, encoding: .utf8) {
            object.removeValue(forKey: "input")
            object["inputText"] = text
        } else {
            return line
        }
        return (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))
            .map { String(decoding: $0, as: UTF8.self) } ?? line
    }

    private static func split(_ line: Data) -> (String, String) {
        let text = String(decoding: line, as: UTF8.self)
        guard let space = text.firstIndex(of: " ") else { return (text, "") }
        return (String(text[..<space]), String(text[text.index(after: space)...]))
    }

    fileprivate static func replaceNumber(_ number: Int32, with replacement: String, in text: String) -> String {
        let digits = String(number)
        guard text.contains(digits) else { return text }
        return replacing("(?<![0-9])\(digits)(?![0-9])", in: text) { _ in replacement }
    }

    private static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// 测试进程的工作目录（检出的位置因人而异）
    private static let workingDirectory = FileManager.default.currentDirectoryPath
    private static let scratch = (NSTemporaryDirectory() as NSString).standardizingPath
    private static let build = PiProcess.cuepad.deletingLastPathComponent().path
    /// 认得出这台机器与这个人的：主机名、电脑名、git 与 Codex 登录里的邮箱
    private static let identity: [(String, String)] = {
        // 主机名大小写因来源而异（ProcessInfo 给小写，gethostname 原样）：两种都换，先长后短
        var buffer = [CChar](repeating: 0, count: 256)
        gethostname(&buffer, buffer.count)
        let hosts = [String(cString: buffer), ProcessInfo.processInfo.hostName]
        var pairs = (hosts + hosts.compactMap { $0.split(separator: ".").first.map(String.init) }).map { ($0, "localhost") }
        if let name = Host.current().localizedName { pairs.append((name, "Mac")) }
        if let output = try? String(contentsOf: FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gitconfig"), encoding: .utf8),
           let email = output.firstMatch(of: /email\s*=\s*(\S+@\S+)/)?.output.1 {
            pairs.append((String(email), "user@example.com"))
        }
        return pairs.filter { $0.0.count >= 4 }
    }()
    private static let jwt = #"eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+"#
    fileprivate static var isoPattern: String { iso }
    fileprivate static var millisecondsPattern: String { milliseconds }
    fileprivate static var secondsPattern: String { seconds }
    private static let iso = #"(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.(\d{1,9}))?(Z|[+-]\d{2}:\d{2})"#
    private static let milliseconds = #"(?<![0-9.])1[6-9][0-9]{11}(?![0-9])"#
    private static let seconds = #"(?<![0-9.])1[6-9][0-9]{8}(?![0-9])"#
    private static let placeholder = #"\{(tmp|dtmp|pid|ms|s|iso|T|build|fixtures|pwd|home)(?::([^{}"\s]*))?\}"#
    private static let window = 2 * 86_400_000.0

    /// 录下前：密钥、路径、pid、时间换成占位符。
    fileprivate static func normalize(_ text: String, _ state: inout State) -> String {
        var text = text.replacing("\\/", with: "/")
        for secret in state.secrets where text.contains(secret) { text = text.replacing(secret, with: "{secret}") }
        text = replacing(jwt, in: text) { _ in "{secret}" }
        for (value, replacement) in identity where text.contains(value) { text = text.replacing(value, with: replacement) }
        let root = state.temporaryRoot, directories = state.temporaryDirectories
        for (form, name) in [(root + "/", "tmp"), (root.replacing("/", with: "-") + "-", "dtmp")] where text.contains(form) {
            text = replacing(NSRegularExpression.escapedPattern(for: form) + "([0-9]+)(?![0-9])", in: text) { groups in
                directories.firstIndex(of: Int(groups[1] ?? "") ?? -1).map { "{\(name):\($0)}" } ?? groups[0]!
            }
        }
        for (path, name) in [(scratch, "T"), (build, "build"), (fixturesDirectory.path, "fixtures"), (workingDirectory, "pwd"), (home, "home")] where text.contains(path) {
            text = text.replacing(path, with: "{\(name)}")
        }
        for (channel, pid) in state.stubPids { text = replaceNumber(pid, with: "{pid:\(channel)}", in: text) }
        let t0 = state.t0
        text = replacing(iso, in: text) { g in
            let (y, mo, d, h, mi, s, fraction, zone) = (g[1]!, g[2]!, g[3]!, g[4]!, g[5]!, g[6]!, g[7], g[8]!)
            var components = DateComponents(year: Int(y), month: Int(mo), day: Int(d), hour: Int(h), minute: Int(mi), second: Int(s))
            components.timeZone = zone == "Z" ? TimeZone(identifier: "UTC") : TimeZone(secondsFromGMT: (zone.hasPrefix("-") ? -1 : 1)
                * ((Int(zone.dropFirst().prefix(2)) ?? 0) * 3600 + (Int(zone.suffix(2)) ?? 0) * 60))
            guard let date = Calendar(identifier: .gregorian).date(from: components) else { return g[0]! }
            let ms = date.timeIntervalSince1970 * 1000 + (Double("0." + (fraction ?? "0")) ?? 0) * 1000
            guard abs(ms - t0) < window else { return g[0]! }
            return "{iso:\(Int((ms - t0).rounded())):\(fraction?.count ?? 0):\(zone)}"
        }
        text = replacing(milliseconds, in: text) { g in
            let ms = Double(g[0]!) ?? 0
            return abs(ms - t0) < window ? "{ms:\(Int(ms - t0))}" : g[0]!
        }
        text = replacing(seconds, in: text) { g in
            let s = Double(g[0]!) ?? 0
            return abs(s * 1000 - t0) < window ? "{s:\(Int(s - (t0 / 1000).rounded(.down)))}" : g[0]!
        }
        return text
    }

    /// 回放时：占位符换回此刻的值。
    fileprivate static func expand(_ text: String, _ state: inout State) -> String {
        guard text.contains("{") else { return text }
        let root = state.temporaryRoot, directories = state.temporaryDirectories, pids = state.stubPids, t0 = state.t0
        return replacing(placeholder, in: text) { g in
            let value = g[2] ?? ""
            switch g[1]! {
            case "tmp", "dtmp":
                guard let index = Int(value), directories.indices.contains(index) else {
                    state.problems.append("回放：录像带里的第 \(value) 个临时目录这次没有建（用例建临时目录的先后变了），重录")
                    return g[0]!
                }
                return g[1] == "tmp" ? "\(root)/\(directories[index])" : "\(root.replacing("/", with: "-"))-\(directories[index])"
            case "T": return scratch
            case "build": return build
            case "fixtures": return fixturesDirectory.path
            case "pwd": return workingDirectory
            case "home": return home
            case "pid": return pids[value].map { String($0) } ?? g[0]!
            case "ms": return String(Int(t0) + (Int(value) ?? 0))
            case "s": return String(Int((t0 / 1000).rounded(.down)) + (Int(value) ?? 0))
            case "iso":
                let parts = value.split(separator: ":", maxSplits: 2).map(String.init)
                guard parts.count == 3, let delta = Double(parts[0]), let digits = Int(parts[1]) else { return g[0]! }
                return isoString(Date(timeIntervalSince1970: (t0 + delta) / 1000), digits: digits, zone: parts[2])
            default: return g[0]!
            }
        }
    }

    /// NSRegularExpression 的替换（Swift Regex 还不支持后行断言）：`transform` 拿到整段与各组（没匹配上的组为 nil）。
    fileprivate static func replacing(_ pattern: String, in text: String, _ transform: ([String?]) -> String) -> String {
        let regex = try! NSRegularExpression(pattern: pattern)
        let source = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            result += transform((0..<match.numberOfRanges).map { match.range(at: $0).location == NSNotFound ? nil : source.substring(with: match.range(at: $0)) })
            last = match.range.location + match.range.length
        }
        return last == 0 ? text : result + source.substring(from: last)
    }

    private static func isoString(_ date: Date, digits: Int, zone: String) -> String {
        let offset = zone == "Z" ? 0 : (zone.hasPrefix("-") ? -1 : 1) * ((Int(zone.dropFirst().prefix(2)) ?? 0) * 3600 + (Int(zone.suffix(2)) ?? 0) * 60)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: offset)!
        let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second, .nanosecond], from: date)
        var text = String(format: "%04d-%02d-%02dT%02d:%02d:%02d", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!)
        if digits > 0 { text += "." + String(String(format: "%09d", c.nanosecond!).prefix(digits)) }
        return text + zone
    }

    private static func substitute(_ text: String, _ replay: Replay) -> String {
        var text = text
        for (recorded, actual) in replay.substitutions where text.contains(recorded) { text = text.replacing(recorded, with: actual) }
        guard !replay.ids.isEmpty, var object = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any],
              let id = object["id"] as? Int, let actual = replay.ids[id] else { return text }
        object["id"] = actual
        return (try? JSONSerialization.data(withJSONObject: object)).map { String(decoding: $0, as: UTF8.self) } ?? text
    }
}

/// 一步录下的事：输入（CuePad 或测试给 Agent 的）与输出（Agent 给 CuePad 的）。
struct TapeEvent: Codable, Sendable {
    /// 种类。输入：spawn、stdin、eof、signal、gone、connect、send、hangup、mark；输出：stdout、stderr、exit、listen、unlisten、recv、close、hook、file、dir
    var k: String
    /// 通道：进程 p<n>、会话 socket s<n>（连接 s<n>.<m>）、钩子调用 h<n>
    var c: String? = nil
    var d: String? = nil
    var p: String? = nil
    var a: [String]? = nil
    /// 启动时环境里 CuePad 给托管进程的标记（`HostMark`）
    var m: String? = nil
    var n: Int? = nil
    /// d 是 base64（不是文本的文件）
    var b: Bool? = nil
    /// 文件是追加
    var ap: Bool? = nil
    /// 回放时算出的：没人叫它退、自己退出的进程（不进录像带）
    var spontaneous: Bool? = nil

    private enum CodingKeys: String, CodingKey { case k, c, d, p, a, m, n, b, ap }

    static let inputs: Set<String> = ["spawn", "stdin", "eof", "signal", "gone", "connect", "send", "hangup", "mark"]
    var isInput: Bool { Self.inputs.contains(k) }
}

enum TapeMode: Sendable {
    case record, replay
    /// 没有录像带，直接连真 Agent（OpenCode）
    case live
}

/// 输入与录下的比对：UUID 不同记成替换（之后的输出里换成这次的），时间与 JSON-RPC 的请求号不同不算；其余不同返回说明。
private enum TapeCompare {
    nonisolated(unsafe) static let uuid = /[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/

    static func compare(expected: String, actual: String, into replay: inout AgentTape.Replay) -> String? {
        // 启动的工作目录与参数逐项比（参数里可能有键序随机的 JSON）
        if expected.contains("\u{1}") || actual.contains("\u{1}") {
            let e = expected.split(separator: "\u{1}", omittingEmptySubsequences: false), a = actual.split(separator: "\u{1}", omittingEmptySubsequences: false)
            guard e.count == a.count else { return "参数个数不同：\(a.count) 而不是 \(e.count)" }
            for (x, y) in zip(e, a) where x != y {
                if let problem = compare(expected: String(x), actual: String(y), into: &replay) { return problem }
            }
            return nil
        }
        let parse = { (text: String) in try? JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed]) }
        guard let e = parse(expected), let a = parse(actual) else { return strings(expected, actual, &replay) }
        return values(e, a, key: nil, &replay)
    }

    private static func values(_ e: Any, _ a: Any, key: String?, _ replay: inout AgentTape.Replay) -> String? {
        switch (e, a) {
        case let (e as [String: Any], a as [String: Any]):
            guard Set(e.keys) == Set(a.keys) else { return "键不同：\(e.keys.sorted()) / \(a.keys.sorted())" }
            for (k, v) in e { if let problem = values(v, a[k]!, key: k, &replay) { return problem } }
            return nil
        case let (e as [Any], a as [Any]):
            guard e.count == a.count else { return "\(key ?? "") 的项数不同" }
            for (x, y) in zip(e, a) { if let problem = values(x, y, key: key, &replay) { return problem } }
            return nil
        case let (e as String, a as String):
            return strings(e, a, &replay)
        case let (e as NSNumber, a as NSNumber):
            if e == a { return nil }
            if key == "id", let x = e as? Int, let y = a as? Int { replay.ids[x] = y; return nil }
            if isTime(e.doubleValue), isTime(a.doubleValue) { return nil }
            return "\(key ?? "") 是 \(a) 而不是 \(e)"
        default:
            return (e as? NSNull != nil && a as? NSNull != nil) ? nil : "\(key ?? "") 的类型不同"
        }
    }

    private static func strings(_ e: String, _ a: String, _ replay: inout AgentTape.Replay) -> String? {
        if e == a { return nil }
        let x = e.matches(of: uuid).map { String($0.output) }, y = a.matches(of: uuid).map { String($0.output) }
        if !x.isEmpty, x.count == y.count, e.replacing(uuid, with: "U") == a.replacing(uuid, with: "U") {
            for (r, n) in zip(x, y) where r != n { replay.substitutions[r] = n }
            return nil
        }
        if timeless(e) == timeless(a) { return nil }  // 只差在此刻的时间
        let same = zip(e, a).prefix { $0 == $1 }.count
        func around(_ text: String) -> String { String(text.dropFirst(max(0, same - 60)).prefix(200)).replacing("\u{1}", with: " ") }
        return "「…\(around(a))」而不是「…\(around(e))」"
    }

    /// 此刻前后两天内的时间（ISO、毫秒、秒）换成同一个记号；别的数字照比
    private static func timeless(_ text: String) -> String {
        var text = AgentTape.replacing(AgentTape.isoPattern, in: text) { _ in "{time}" }
        for pattern in [AgentTape.millisecondsPattern, AgentTape.secondsPattern] {
            text = AgentTape.replacing(pattern, in: text) { groups in
                let value = Double(groups[0] ?? "") ?? 0
                return isTime(value) ? "{time}" : groups[0]!
            }
        }
        return text
    }

    private static func isTime(_ value: Double) -> Bool {
        let now = Date().timeIntervalSince1970
        return abs(value - now) < 2 * 86_400 || abs(value / 1000 - now) < 2 * 86_400
    }
}

/// 套件上的录像带：每个用例（参数化的每组参数）一盘，模式见 `RealAgents`。
struct AgentTapeTrait: SuiteTrait, TestTrait, TestScoping {
    let agent: AgentKind?
    var isRecursive: Bool { true }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> AgentTapeTrait? { testCase == nil ? nil : self }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @concurrent @Sendable () async throws -> Void) async throws {
        let tape = try AgentTape(agent: agent, test: test)
        try await AgentTape.$current.withValue(tape) {
            do {
                try await function()
            } catch {
                await tape.finish(keep: false)
                throw error
            }
            await tape.finish()
        }
    }
}

extension Trait where Self == AgentTapeTrait {
    /// 这家的真 Agent 用例：默认回放录像带，`CUEPAD_AGENT_TESTS` 列出这家时连真 Agent 跑并重录。
    static func agentTape(_ agent: AgentKind) -> Self { AgentTapeTrait(agent: agent) }
    /// 几家共用的套件：用例里用 `AgentTape.use(_:variant:)` 给出这一盘是哪家的。
    static var agentTapes: Self { AgentTapeTrait(agent: nil) }
}

let fixturesDirectory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)

#endif
