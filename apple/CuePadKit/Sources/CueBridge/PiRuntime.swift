#if os(macOS)
import CueStore
import Foundation

@MainActor
public final class PiRuntime: AgentRuntime {
    private let bridge: Bridge
    private let paths: PiPaths
    private let brief: String
    private let pi: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    private let idleLimit: Duration
    private let timing: Timing
    private let resumptions = Resumptions()

    public init(
        bridge: Bridge, paths: PiPaths, brief: String, pi: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system },
        idleLimit: Duration = AgentTimeouts.hostedIdle, timing: Timing = .system
    ) {
        self.bridge = bridge
        self.paths = paths
        self.brief = brief
        self.pi = pi
        self.locate = locate
        self.idleLimit = idleLimit
        self.timing = timing
    }

    public func start() {}

    public func stop() -> @concurrent @Sendable () async -> Void { {} }

    public var hostedSessionsOutliveApp: Bool { true }

    /// 等它连上桥后返回。会话名、模型与思考强度是 Pi 的启动参数（`--name`、`--model`、`--thinking`），给了就一起生效；模型不存在、没登录这类起来就退出的，抛 `exited` 并带上 Pi 的原话。
    public func open(
        in directory: URL, launchToken: String, name: String?, model: ModelKey?, thinking: ThinkingLevel?
    ) async throws -> Session.ID {
        var arguments: [String] = []
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { arguments += ["--name", name] }
        if let model { arguments += ["--model", "\(model.provider)/\(model.id)"] }
        if let thinking { arguments += ["--thinking", thinking.rawValue] }
        return try await launch(arguments, in: directory, environment: ["CUEPAD_LAUNCH_TOKEN": launchToken]).id
    }

    public func resume(_ session: IndexedSession) async throws -> Session.ID {
        try await resumptions.resume(session.id) { [self] in
            try await launch(["--session", session.path], in: URL(filePath: session.cwd, directoryHint: .isDirectory), environment: [:]).id
        }
    }

    nonisolated static let hostedVariable = "CUEPAD_HOSTED"

    private func launch(_ arguments: [String], in directory: URL, environment: [String: String]) async throws -> Session {
        guard let executable = await pi() else { throw AgentRuntimeError.notInstalled(.pi) }
        let changes = bridge.changes()
        let environment = await locate().environment(
            launching: executable,
            overrides: paths.launchEnvironment.merging(environment) { $1 }.merging([Self.hostedVariable: String(idleLimit.components.seconds)]) { $1 })
        // 脱离 App：新会话、标准输入是它自己握着两端的管道（RPC 模式读到 EOF 就收尾，这样永远读不到）；认领前 App 只握着看守的那根；
        // RPC 输出接空设备，只消费桥扩展的公开事件；标准错误只读到认领为止，留给起来就退出时的原因（`ChildProcess.release()`）。
        let process = try await ChildProcess(
            executable, ["--mode", "rpc", "--extension", PiExtensionBundle.url.path, "--append-system-prompt", brief] + arguments, directory: directory, environment: environment,
            placement: .detached, input: .lifeline)
        let pid = process.pid
        let session: Session
        do {
            session = try await withDeadline(AgentTimeouts.launch, timing: timing, orThrow: PiHostError.notConnected) {
                try await withThrowingTaskGroup(of: Session?.self) { group in
                    group.addTask {
                        for await change in changes {
                            if case .appeared(let session) = change, session.pid == pid { return session }
                        }
                        return nil
                    }
                    group.addTask {
                        guard await process.exited(within: nil) else { return nil }
                        let line = process.stderrTail.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                        throw PiHostError.exited(line.map { String($0.prefix(300)).trimmingCharacters(in: .whitespaces) })
                    }
                    defer { group.cancelAll() }
                    guard let session = try await group.next() ?? nil else { throw CancellationError() }
                    return session
                }
            }
        } catch {
            process.end()
            throw error
        }
        process.release()
        return session
    }
}

public enum PiHostError: Error, Equatable {
    case exited(String?)
    case notConnected
}

extension PiHostError: ShownError {
    public var shown: String.LocalizationValue {
        switch self {
        case .exited(let reason): reason.map { "在后台启动的 Pi 没连上就退出了：\($0)" } ?? "在后台启动的 Pi 没连上就退出了"
        case .notConnected: "在后台启动的 Pi 一直没连上"
        }
    }
}
#endif
