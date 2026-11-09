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

    static var active: AgentTape {
        guard let current else { fatalError("这个用例没有录像带：套件上加 .agentTape(<家>)") }
        return current
    }

    let baseName: String
    let directory: URL
    var bin: URL { directory.appending(path: "bin", directoryHint: .isDirectory) }
    var control: String { directory.appending(path: "t.sock").path }
    var inner: URL { directory.appending(path: "i", directoryHint: .isDirectory) }
    let state: Mutex<State>
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

    static let realExecutables: [String: URL?] = ["pi": pinnedPi.executable, "codex": pinnedCodex.executable, "claude": pinnedClaude.executable, "grok": pinnedGrok.executable, "dsh": PinnedAgent.dsh.executable]

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
    var mode: TapeMode { agent.map(RealAgents.mode(of:)) ?? .replay }

    // MARK: 用例的接口

    static func variant(_ name: String) {
        active.state.withLock { $0.variant = name }
    }

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

    func executable(_ name: String) -> URL {
        mode == .live ? (Self.realExecutables[name] ?? nil) ?? bin.appending(path: name) : bin.appending(path: name)
    }

    static func executable(_ name: String) -> URL { current?.executable(name) ?? (realExecutables[name] ?? nil)! }
    static func locator(_ name: String) -> ExecutableLocator { ExecutableLocator(searchDirectories: [executable(name).deletingLastPathComponent()]) }

    /// `named`：目录里还有 CuePad 不读的大文件时只录叫这个名字的。
    func watch(_ urls: URL..., named: String? = nil) {
        guard mode == .record else { return }
        state.withLock { $0.watched += urls.map { ($0.path, named) } }
    }

    func mark(_ name: String) {
        switch mode {
        case .record: record(TapeEvent(k: "mark", c: "mark", d: name))
        case .replay: input("mark", channel: "mark", data: name)
        case .live: break
        }
    }

    func secret(_ values: String?...) {
        state.withLock { $0.secrets += values.compactMap { $0 }.filter { $0.count >= 8 } }
    }

    func secret(tokens object: Any) {
        switch object {
        case let dictionary as [String: Any]: dictionary.values.forEach { secret(tokens: $0) }
        case let string as String:
            secret(string)
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
        var events: [TapeEvent] = []
        var files: [String: FileShot] = [:]
        var processCount = 0
        var socketCount = 0
        var hookCount = 0
        var socketChannels: [String: (channel: String, connections: Int)] = [:]
        var realToStub: [Int32: Int32] = [:]
        var realGroups: [Int32] = []
        var outerSockets: String?
        var stubPids: [String: Int32] = [:]
        var stubs: [String: Stub] = [:]
        var connections: [String: Connection] = [:]
        var listeners: [String: (source: DispatchSourceRead, path: String)] = [:]
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

struct TapeEvent: Codable, Sendable {
    var k: String
    /// 通道：进程 p<n>、会话 socket s<n>（连接 s<n>.<m>）、钩子调用 h<n>
    var c: String? = nil
    var d: String? = nil
    var p: String? = nil
    var a: [String]? = nil
    var m: String? = nil
    var n: Int? = nil
    var b: Bool? = nil
    var ap: Bool? = nil
    /// 回放时算出的：没人叫它退、自己退出的进程（不进录像带）
    var spontaneous: Bool? = nil

    private enum CodingKeys: String, CodingKey { case k, c, d, p, a, m, n, b, ap }

    static let inputs: Set<String> = ["spawn", "stdin", "eof", "signal", "gone", "connect", "send", "hangup", "mark"]
    var isInput: Bool { Self.inputs.contains(k) }
}

enum TapeMode: Sendable {
    case record, replay
    case live
}

let fixturesDirectory = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures", directoryHint: .isDirectory)

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
    static func agentTape(_ agent: AgentKind) -> Self { AgentTapeTrait(agent: agent) }
    static var agentTapes: Self { AgentTapeTrait(agent: nil) }
}
#endif
