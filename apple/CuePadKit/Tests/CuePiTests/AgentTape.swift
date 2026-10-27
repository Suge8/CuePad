#if os(macOS)
import CryptoKit
import CueStore
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

    let baseName: String
    /// 录像带自己的目录：替身（`bin`）、替身连回来的 socket、录制时真 Agent 用的 socket 目录（`i`）
    let directory: URL
    var bin: URL { directory.appending(path: "bin", directoryHint: .isDirectory) }
    var control: String { directory.appending(path: "t.sock").path }
    var inner: URL { directory.appending(path: "i", directoryHint: .isDirectory) }
    let state: Mutex<State>
    /// 回放：有新的输入到了就叫醒做输出的那条任务
    let wakes = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
    var emitting: Task<Void, Never>?
    var controlSource: DispatchSourceRead?
    var hookSource: DispatchSourceRead?
    let stopped = Atomic(false)

    /// 编译好的替身（`Fixtures/tape-stub.c`）：按源码的哈希缓存在临时目录，本机第一次用时编译一次。
    static let stub: Result<URL, any Error> = Result {
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
    static let realExecutables: [String: URL?] = ["pi": realPiURL, "codex": realCodexURL, "claude": claudeURL, "grok": realGrokURL, "dsh": realDshURL]

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

    static func type(of line: String) -> String? {
        ((try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any])?["type"] as? String
    }

    /// 这家在录像带里的替身（交给 CuePad 当可执行文件，或放进它的查找目录）；直接连真 Agent 时是真的。
    func executable(_ name: String) -> URL {
        mode == .live ? (Self.realExecutables[name] ?? nil) ?? bin.appending(path: name) : bin.appending(path: name)
    }

    /// 当前用例里这家的可执行文件：有录像带用替身，没有录像带（只连真 Agent）的用例用真的。
    static func executable(_ name: String) -> URL { current?.executable(name) ?? (realExecutables[name] ?? nil)! }
    static func locator(_ name: String) -> ExecutableLocator { ExecutableLocator(searchDirectories: [executable(name).deletingLastPathComponent()]) }

    /// 录制时盯着这些目录里 Agent 写出的文件（会话文件、工作目录里的产物）；给了 `named` 只录叫这个名字的（目录里还有 CuePad 不读的大文件时）。
    func watch(_ urls: URL..., named: String? = nil) {
        guard mode == .record else { return }
        state.withLock { $0.watched += urls.map { ($0.path, named) } }
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

    var file: URL {
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
            for pid in pids { try? await eventually("真 Agent 进程组 \(pid) 退出") { killpg(pid, 0) != 0 } }
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

    struct State {
        var t0: Double
        var temporaryRoot: String
        var temporaryDirectories: [Int]
        var agent: AgentKind?
        var variant: String?
        var proxying = false
        var secrets: [String] = []
        var watched: [(path: String, named: String?)] = []
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
        /// 回放时钟（`expand`）：录下的时刻（相对 `t0` 的毫秒）→ 回放给出的时刻；`lag` 是回放比录制慢出的毫秒数，只增不减
        var replayed: [Double: Double] = [:]
        var lag = 0.0
        var latest = -Double.infinity
    }

    struct FileShot {
        var size: Int
        var modified: timespec
        var inode: ino_t
        /// 已经录下的内容（追加时只录新的完整行）
        var content: Data
    }

    struct Replay {
        var events: [TapeEvent]
        var matched: [Bool]
        var cursor = 0
        var substitutions: [String: String] = [:]
        var ids: [Int: Int] = [:]

        var firstUnmatchedInput: (index: Int, event: TapeEvent)? {
            events.indices.first { events[$0].isInput && !matched[$0] }.map { ($0, events[$0]) }
        }
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

let fixturesDirectory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)

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
#endif
