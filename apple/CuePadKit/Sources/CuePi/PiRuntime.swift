#if os(macOS)
import CueStore
import Darwin
import Foundation
import OSLog

/// Pi 的接入：会话由桥经扩展的 socket 发现（`PiBridge`）；CuePad 在后台托管的 Pi 没有终端界面，以 RPC 模式运行（`pi --mode rpc`），
/// 状态与消息都走桥。给已结束的会话发消息时恢复它（`resume`），开新会话（`open`）。
///
/// 托管的进程与终端里开的会话是同一个模型：它自己管生死，CuePad 只是连上去看和发的客户端。
/// - 脱离 App（`ChildProcess.Placement.detached`）：连上桥、确认读得懂托管约定后认领它，之后 App 退出、更新、崩溃都不影响它，
///   新起的 App 经桥重新看到它；认领之前 App 没了，它随之结束（这时它还什么都没收到）；
/// - 经环境变量 `CUEPAD_HOSTED`（值是空闲多少秒后退出，格式见 README「协议」）告诉扩展：扩展在 hello 里带回（`PiSession.hosted`），
///   空闲（这一轮做完、没有等你确认、子代理也歇下）满时限就自己退出；
/// - 有哪些托管会话只看桥（`hosted` 与 hello 里的 pid），这里不记进程；结束、让出由桥做（`PiBridge` 的托管会话一节）；
/// - 让出的那个退出后，让接手的进程重新载入会话（`PiBridge.reload`）：它这期间没写过就接上那一轮、不分支，写过就由扩展提示一句。
@MainActor
public final class PiRuntime: AgentRuntime {
    private static let log = Logger(subsystem: AppIdentity.id, category: "pi-host")
    private let bridge: PiBridge
    private let paths: PiPaths
    private let pi: @Sendable () async -> URL?
    private let locate: @Sendable () async -> ExecutableLocator
    private let idleLimit: Duration
    private let timing: Timing
    private var watcher: Task<Void, Never>?

    /// - Parameter pi: 这台 Mac 上够新的 `pi`（检测时挑中的那个，`AgentStatus.executable`；没有为 nil）。
    /// - Parameter idleLimit: 托管进程空闲多久自己退出（交给扩展计时）。
    /// - Parameter timing: 量起进程到上桥时限的钟。
    public init(
        bridge: PiBridge, paths: PiPaths, pi: @escaping @Sendable () async -> URL?,
        locate: @escaping @Sendable () async -> ExecutableLocator = { await .system },
        idleLimit: Duration = AgentTimeouts.hostedIdle, timing: Timing = .system
    ) {
        self.bridge = bridge
        self.paths = paths
        self.pi = pi
        self.locate = locate
        self.idleLimit = idleLimit
        self.timing = timing
    }

    /// 开始跟着桥上的会话：让出的托管会话退出后让接手的重新载入。
    public func start() {
        guard watcher == nil else { return }
        let changes = bridge.changes()
        watcher = Task { [weak self] in
            for await change in changes {
                if case .ended(let session, _) = change { self?.reloadSuccessor(of: session) }
            }
        }
    }

    /// 托管的 Pi 会话不随 CuePad 退出（新会话组、空闲由扩展自退），没有要关的。
    public func stop() -> @concurrent @Sendable () async -> Void { {} }

    /// 新装或升级了扩展：请在跑的会话换上新扩展（`PiBridge.offerExtensionUpgrade`）。
    public func integrationInstalled() { bridge.offerExtensionUpgrade() }

    /// 认领后的托管进程脱离 App；App 更新后也一样，它歇下时换上新扩展、重新连回。
    public var hostedSessionsOutliveApp: Bool { true }

    /// 在后台于 `directory` 开一个新会话，带上发起方的认领标识；等它连上桥后返回。会话名、模型与思考强度是 Pi 的启动参数
    /// （`--name`、`--model`、`--thinking`），给了就一起生效；模型不存在或没登录时 Pi 起来就退出，抛 `exited` 并带上 Pi 的原话。
    public func open(
        in directory: URL, launchToken: String, name: String?, model: PiModelKey?, thinking: PiThinkingLevel?
    ) async throws -> PiSession.ID {
        var arguments: [String] = []
        if let name, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { arguments += ["--name", name] }
        if let model { arguments += ["--model", "\(model.provider)/\(model.id)"] }
        if let thinking { arguments += ["--thinking", thinking.rawValue] }
        return try await launch(arguments, in: directory, environment: ["CUEPAD_LAUNCH_TOKEN": launchToken]).id
    }

    /// 在后台恢复这个会话（会话文件，于它的工作目录），等它连上桥后返回。
    public func resume(_ session: IndexedSession) async throws -> PiSession.ID {
        try await launch(["--session", session.path], in: URL(filePath: session.cwd, directoryHint: .isDirectory), environment: [:]).id
    }

    // MARK: 进程

    /// 扩展读这个环境变量判断自己是被 CuePad 托管的，值是空闲多少秒后退出。
    static let hostedVariable = "CUEPAD_HOSTED"

    /// 启动并等它的会话连上桥；进程先退出或超时（这时让它退出）都抛错。
    /// 连上的扩展必须读得懂托管约定（报出 `hosted`、CuePad 读得懂它）：不然起出的进程既不会空闲自退、CuePad 也不认它是托管的，
    /// 成了没人管的孤儿。磁盘上的扩展不是随包版本（接入修复失败、Pi 太旧没修、别人改过）时就是这样，这时让它退出并报错。
    private func launch(_ arguments: [String], in directory: URL, environment: [String: String]) async throws -> PiSession {
        guard let executable = await pi() else { throw AgentRuntimeError.notInstalled(.pi) }
        let changes = bridge.changes()  // 先订阅再启动：连上的那一刻不会漏
        let environment = await locate().environment(
            launching: executable,
            overrides: paths.launchEnvironment.merging(environment) { $1 }.merging([Self.hostedVariable: String(idleLimit.components.seconds)]) { $1 })
        // 脱离 App：新会话、标准输入是它自己握着两端的管道（RPC 模式读到 EOF 就收尾，这样永远读不到）；认领前 App 只握着看守的那根；
        // 标准输出丢掉（RPC 的事件与回应走桥），标准错误留着，没连上就退出时取最后一行当原因
        let process = try await ChildProcess(
            executable, ["--mode", "rpc"] + arguments, directory: directory, environment: environment,
            placement: .detached, input: .lifeline)
        let pid = process.pid
        let session: PiSession
        do {
            session = try await withDeadline(AgentTimeouts.launch, timing: timing, orThrow: PiHostError.notConnected) {
                try await withThrowingTaskGroup(of: PiSession?.self) { group in
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
        // 刚起的就读到不同的扩展：装着的扩展与 App 不配套，它不会自己重新载入，让它退出
        guard session.hosted, !session.upgrading else {
            process.end()
            throw PiHostError.extensionMismatch
        }
        process.release()
        return session
    }

    /// 让出的托管会话退出了：接手的进程把会话重新载入到最新（让出前做完的那一轮它还没看到）。
    private func reloadSuccessor(of session: PiSession) {
        guard session.agent == .pi, session.hosted,
              let successor = bridge.sessions.first(where: { $0.agent == .pi && $0.sessionID == session.sessionID && !$0.hosted }) else { return }
        Task {
            do { try await bridge.reload(successor.id) } catch { Self.log.notice("让接手的会话重新载入失败：\(String(describing: error))") }
        }
    }
}

public enum PiHostError: Error, Equatable {
    /// 后台启动的 Pi 还没连上就退出了（Pi 在标准错误里说的最后一句；没说为 nil）
    case exited(String?)
    /// 等了很久 Pi 都没连上（已让它退出）
    case notConnected
    /// Pi 加载的 CuePad 扩展不是这个版本的，不能托管（已让它退出）
    case extensionMismatch
}

extension PiHostError: ShownError {
    public var shown: String.LocalizationValue {
        switch self {
        case .exited(let reason): reason.map { "在后台启动的 Pi 没连上就退出了：\($0)" } ?? "在后台启动的 Pi 没连上就退出了"
        case .notConnected: "在后台启动的 Pi 一直没连上"
        case .extensionMismatch: "Pi 里的 CuePad 扩展不是这个版本的，没能在后台启动；在 CuePad 设置里修复 Pi 接入后再发"
        }
    }
}
#endif
