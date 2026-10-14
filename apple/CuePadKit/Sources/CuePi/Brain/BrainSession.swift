#if os(macOS)
import Foundation
import Synchronization

/// 一个大脑的运行骨架，三家共用：事件流、子进程（`BrainProcess`）、本次运行的临时目录、等回应的请求。
/// 三家只给启动参数、请求怎么封装、每行输出怎么解析；进程退出时（不论谁让它退的）等着的请求以 `notRunning` 失败、
/// 临时目录删掉、发 `exited` 并结束事件流。
final class BrainSession: Sendable {
    let events: AsyncStream<CueBrainEvent>
    private let emitter: AsyncStream<CueBrainEvent>.Continuation
    private struct State {
        var process: BrainProcess?
        var runner: Task<Void, Never>?
        var directory: URL?
        var waiting: [String: CheckedContinuation<[String: Any], any Error>] = [:]
        var nextID = 0
        /// 进程已退出：之后的请求直接 `notRunning`
        var ended = false
    }
    private let state = Mutex(State())

    init() {
        (events, emitter) = AsyncStream.makeStream(bufferingPolicy: .unbounded)
    }

    func emit(_ event: CueBrainEvent) {
        emitter.yield(event)
    }

    /// 起运行时并握手。`arguments` 拿到本次运行的临时目录（放系统提示等）；每行输出里 `replyID` 认得出的是请求的回应，
    /// 交给等它的 `request`，其余交给 `receive`。握手失败时停掉进程、删掉临时目录再抛：调用方拿不到这个大脑，没人能收拾。
    func start(
        _ config: CueBrainConfig, environment extra: [String: String] = [:], arguments: (URL) throws -> [String],
        replyID: @escaping @Sendable ([String: Any]) -> String?, receive: @escaping @Sendable (sending [String: Any]) async -> Void,
        handshake: () async throws -> Void = {}
    ) async throws {
        guard state.withLock({ $0.process == nil }) else { return }
        do {
            let directory = FileManager.default.temporaryDirectory.appending(path: "cue-brain-\(UUID().uuidString)", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            state.withLock { $0.directory = directory }
            let process = try BrainProcess(
                executable: config.executable, arguments: arguments(directory), directory: config.workingDirectory,
                environment: Self.environment(config, extra))
            let runner = Task { await self.run(process, replyID: replyID, receive: receive) }
            state.withLock { $0.process = process; $0.runner = runner }
            try await handshake()
        } catch {
            await stop()
            removeDirectory()
            throw error
        }
    }

    /// 发一条请求、等它的回应（原样返回，成败由各家按自己的格式判断）。`frame` 用分到的 id 拼出要写的那一行。
    func request(_ frame: (String) -> [String: Any]) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { continuation in
            let (process, id) = state.withLock { s -> (BrainProcess?, String) in
                s.nextID += 1
                let id = "cue-\(s.nextID)"
                guard let process = s.process, !s.ended else { return (nil, id) }
                s.waiting[id] = continuation
                return (process, id)
            }
            guard let process else { return continuation.resume(throwing: CueBrainError.notRunning) }
            do { try process.write(frame(id)) } catch { state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(throwing: error) }
        }
    }

    /// 写一行，不等回应（发话、回运行时的请求）。
    func write(_ object: [String: Any]) throws {
        guard let process = state.withLock({ $0.ended ? nil : $0.process }) else { throw CueBrainError.notRunning }
        try process.write(object)
    }

    /// 结束进程并等它（连同它起的子进程）退出；返回时 `exited` 已发出。
    func stop() async {
        let (process, runner) = state.withLock { ($0.process, $0.runner) }
        await process?.stop()
        await runner?.value
        state.withLock { $0.process = nil }
    }

    private func run(
        _ process: BrainProcess, replyID: @Sendable ([String: Any]) -> String?, receive: @Sendable (sending [String: Any]) async -> Void
    ) async {
        let reason = await process.pump { line in
            guard let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { return }
            if let id = replyID(message) {
                state.withLock { $0.waiting.removeValue(forKey: id) }?.resume(returning: message)
            } else {
                await receive(message)
            }
        }
        let waiting = state.withLock { s in
            s.ended = true
            defer { s.waiting = [:] }
            return s.waiting.values
        }
        for continuation in waiting { continuation.resume(throwing: CueBrainError.notRunning) }
        removeDirectory()
        emitter.yield(.exited(reason))
        emitter.finish()
    }

    private func removeDirectory() {
        if let directory = state.withLock({ s in defer { s.directory = nil }; return s.directory }) {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    /// 运行时的环境：CuePad 自己的环境加上配置给的；可执行文件所在目录放到 PATH 最前（`pi` 是 node 脚本，App 的环境里没有用户 shell 的 PATH，
    /// node 多半与它装在一起）。
    private static func environment(_ config: CueBrainConfig, _ extra: [String: String]) -> [String: String] {
        var environment = ProcessInfo.processInfo.environment.merging(config.environment) { _, new in new }.merging(extra) { _, new in new }
        let path = environment["PATH"].map { ":" + $0 } ?? ""
        environment["PATH"] = config.executable.deletingLastPathComponent().path + path
        return environment
    }
}

func jsonString(_ object: Any) -> String {
    String(decoding: (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])) ?? Data(), as: UTF8.self)
}
#endif
