#if os(macOS)
import CuePi
import CueStore
import CueText
import Foundation
import Observation
import os

/// 管理器的外部依赖；`MacDependencies.cue` 给出，测试换成替身。
struct CueDependencies {
    /// 起大脑前找可执行文件与可选的 Agent 和模型（生产是 `CueLaunch.local`，不问登录）
    var launch: @Sendable (AgentKind, CueStore) async throws -> CueLaunch?
    /// App 里的 `cuepad` 命令行：Cue 的 MCP 服务
    var helper: URL
    var notifier: any CueNotifying
    var timing = CueTiming()
}

/// 起一个大脑要的本机信息。
nonisolated struct CueLaunch: Equatable, Sendable {
    var executable: URL
    /// 给大脑与 MCP 服务的 PATH（`ExecutableLocator.system`）：App 自己的 PATH 很短，运行时起的 node 等靠它找到。
    var path: String
    /// 开会话能用的 Agent 与模型（`CuePrompt.system` 的 `agents`）
    var agents: [MacAgent]

    /// 这台 Mac 上起 `runtime` 的大脑：按 `ExecutableLocator.system` 找可执行文件，不问登录（登录不了大脑起不来或一轮出错，由管理器报出）；
    /// 能用的 Agent 与模型是这台 Mac 写下的那条（`CueStore.macAgents`）。没装为 nil。
    @concurrent static func local(_ runtime: AgentKind, store: CueStore, host: String) async throws -> CueLaunch? {
        let locator = await ExecutableLocator.system
        guard let executable = locator.executable(runtime) else { return nil }
        return CueLaunch(executable: executable, path: locator.path, agents: try await store.macAgents(on: host).agents)
    }
}

/// Cue 的通知出口（Mac 本机）：生产是 `AlertCenter`（点开去哪、开关、提示音、前台怎么呈现都在那里），测试换成记录型替身。
protocol CueNotifying: AnyObject {
    /// 你正看着 Cue 页：这时不发本机通知，也不给手机推送。
    var isWatchingCue: Bool { get }
    func post(title: String, body: String) async
}

/// Mac 上的 Cue：界面的唯一接口（`services.cue`）。手机与别的 Mac 不跑这里，界面直接读写库（`cueProfile` 等）。
/// - 启用、停用经这里写，与别处改设置同一个写入口（`AppServices.updateCue`，写完立即上传）。
/// - 启用：住到这台 Mac、记下启用时刻，你选的运行时、模型、强度不动；选的运行时这台用不了（不在这台 Mac 能用的 Agent 里：启用前
///   重新问一次并写下，`MacAgentsRecorder.record`，再按库里的判断）才换成 `CueProfile.runtimes` 里第一家能用的，模型随原来那家清掉；
///   一家都不能用时报出各家为什么不能用（`MacAgents.whyNone`）；
///   另一台 Mac 启用就是接管，这台看到 `activeHost` 不是自己就停下。停用只清 `enabledAt`。
/// - `activeHost` 是这台时起一个 `CueKeeper` 值班，不是就停掉；名字、运行时、模型、强度变了由值班的它自己对上（就地换或写交接后换大脑）。
/// - 通知只推"等你"（带选项的 Cue 消息）与 urgent 的 Cue 消息，只由值班的这台 Mac 判断：你没在看 Cue 页时，这台 Mac 发本机通知
///   （算"等你"那种提示，开关与提示音在设置里），并给消息置推送标志（`CueStore.flagCueMessageForPush`），手机由服务端订阅推送（见 `AlertSubscriptions`）。
///   免打扰只认系统的专注模式，不看打扰时段（那只管 Cue 自己巡视，`CueTiming.quietHours`）。
@Observable
final class CueService {
    /// Cue 在这台 Mac 值班（同步据此按节奏拉取，见 `AppServices.pollingCadence`）。
    var onDuty: Bool { duty != nil }
    /// 在这台 Mac 值班的管理器：Cue 页的"运行情况"读它的经过与上下文；不在这里值班为 nil。
    var keeper: CueKeeper? { duty?.keeper }
    @ObservationIgnored private let store: CueStore
    @ObservationIgnored private let sync: (any SyncControlling)?
    @ObservationIgnored private let hostID: String
    @ObservationIgnored private let macAgents: MacAgentsRecorder
    @ObservationIgnored private let library: URL
    @ObservationIgnored private let piAgentDirectory: URL
    @ObservationIgnored private let dependencies: CueDependencies
    private var duty: (keeper: CueKeeper, task: Task<Void, Never>)?
    private nonisolated static let log = Logger(subsystem: AppServices.bundleID, category: "cue")

    init(
        store: CueStore, sync: (any SyncControlling)?, hostID: String, macAgents: MacAgentsRecorder, library: URL, piAgentDirectory: URL,
        dependencies: CueDependencies
    ) {
        self.store = store
        self.sync = sync
        self.hostID = hostID
        self.macAgents = macAgents
        self.library = library
        self.piAgentDirectory = piAgentDirectory
        self.dependencies = dependencies
    }

    enum EnableError: LocalizedError {
        /// 参数是各家为什么不能用
        case noRuntime(String)
        var errorDescription: String? {
            switch self {
            case .noRuntime(let why): "这台 Mac 上没有能当 Cue 的 Agent：\(why)"
            }
        }
    }

    /// 让 Cue 住在这台 Mac 并启用（另一台 Mac 上的会停下）：只改住在哪、启用时刻。选的 Agent 这台用不了才换成第一家能用的，
    /// 模型属于原来那家，一并清掉；强度留着（运行时自己取档）。
    func enable() async throws {
        let agents = try await macAgents.record()
        let available = CueProfile.runtimes.filter(agents.kinds.contains)
        guard let first = available.first else { throw EnableError.noRuntime(agents.whyNone) }
        try await update { [hostID] profile in
            profile.hostID = hostID
            profile.enabledAt = .now
            if profile.runtime.known.map(available.contains) != true {
                profile.runtime = .known(first)
                profile.model = nil
            }
        }
    }

    func disable() async throws {
        try await update { $0.enabledAt = nil }
    }

    private func update(_ edit: @escaping @Sendable (inout CueProfile) -> Void) async throws {
        try await AppServices.updateCue(edit, store: store, sync: sync)
    }

    /// 跟着设置值班，直到任务取消。
    func follow() async throws {
        do {
            for try await profile in store.observe({ try $0.cueProfile() }) { await apply(profile) }
        } catch {
            await endDuty()
            if !(error is CancellationError) { throw error }
        }
        await endDuty()
    }

    /// 退出收尾：立即不再值班；返回的过程等大脑退出，再等值班收尾（正在起的大脑起好后由值班停掉）。
    /// 已在跑的大脑不经主线程就停（见 `AppServices.beginShutdown`）；正在起的那个要等主线程把值班走完。
    func stop() -> @Sendable () async -> Void {
        guard let duty else { return {} }
        self.duty = nil
        let stopping = duty.keeper.stop(), task = duty.task, store = store
        return {
            await stopping()
            await Self.rest(store)
            await task.value
        }
    }

    private func apply(_ profile: CueProfile?) async {
        guard profile?.activeHost == hostID else { return await endDuty() }
        guard duty == nil else { return }
        let keeper = CueKeeper(
            CueKeeper.Setup(
                store: store, launch: { [launch = dependencies.launch, store] in try await launch($0, store) },
                helper: dependencies.helper, library: library,
                piAgentDirectory: piAgentDirectory, directory: library.appending(path: "Cue", directoryHint: .isDirectory), timing: dependencies.timing,
                upload: { [sync] ids in for id in ids { await sync?.upload(id) } }))
        duty = (keeper, Task { await keeper.run() })
    }

    private func endDuty() async {
        guard let duty else { return }
        self.duty = nil
        duty.keeper.stop()
        await duty.task.value
        await Self.rest(store)
    }

    /// 不再值班：库里写回歇着，别的设备不会一直看到它在想（不在主线程上等，退出收尾时也能写）。
    private nonisolated static func rest(_ store: CueStore) async {
        do {
            try await store.setCueState(.settled)
        } catch {
            log.error("Cue 歇着没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 通知

    /// 推"等你"与 urgent 的 Cue 消息，直到任务取消。只推这次启动之后新写的；你正看着 Cue 页时不推。
    func followNotifications() async throws {
        let since = Date.now
        var seen = Set<UUID>()
        for try await messages in store.observe({ try $0.cueMessages(limit: 20) }) {
            let fresh = messages.filter {
                $0.author == .known(.cue) && $0.createdAt >= since && ($0.choices != nil || $0.urgent) && !seen.contains($0.id)
            }
            seen.formUnion(fresh.map(\.id))
            guard duty != nil, !dependencies.notifier.isWatchingCue else { continue }
            let name = (try? await store.cueProfile())?.name
            for message in fresh {
                var task: String?
                if let id = message.taskID { task = try? await store.card(id)?.heading }
                let alert = CueAlert.content(name: name, text: message.text, choices: message.choices, task: task)
                await dependencies.notifier.post(title: alert.title, body: alert.body)
                do {
                    try await store.flagCueMessageForPush(message.id)
                } catch {
                    Self.log.error("Cue 消息没能标上手机推送：\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}
#endif
