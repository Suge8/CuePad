#if os(macOS)
import CueStore
import CueText
import Foundation
import Observation
import os

/// 管理器的外部依赖；`MacDependencies.cue` 给出，测试换成替身。
struct CueDependencies {
    /// 查本机装了且登录了的运行时（生产是 `CueRuntimes.scan`，慢）
    var scan: @Sendable () async -> [AgentKind]
    /// 起大脑前找可执行文件与可选的 Agent 和模型（生产是 `CueRuntimes.launch`，不问登录）
    var launch: @Sendable (AgentKind, CueStore) async -> CueLaunch?
    /// App 里的 `cuepad` 命令行：Cue 的 MCP 服务
    var helper: URL
    var notifier: any CueNotifying
    var timing = CueTiming()
}

/// Cue 的通知出口（Mac 本机）：生产是 `AlertCenter`（点开去哪、开关、提示音、前台怎么呈现都在那里），测试换成记录型替身。
protocol CueNotifying: AnyObject {
    /// 你正看着 Cue 页：这时不发本机通知，也不给手机推送。
    var isWatchingCue: Bool { get }
    func post(title: String, body: String) async
}

/// Mac 上的 Cue：界面的唯一接口（`services.cue`）。手机与别的 Mac 不跑这里，界面直接读写库（`cueProfile` 等）。
/// - 设置只经这里写（启用、停用、`update`），写完立即上传：手机与别的 Mac 马上看到。
/// - 启用：住到这台 Mac、记下启用时刻，你选的运行时、模型、强度不动；选的运行时这台用不了（没装或没登录）才换成
///   `CueRuntimes.order` 里第一家能用的，模型随原来那家清掉；
///   另一台 Mac 启用就是接管，这台看到 `activeHost` 不是自己就停下。停用只清 `enabledAt`。
/// - `activeHost` 是这台时起一个 `CueKeeper` 值班；名字、运行时、模型、强度变了就换一个（新班次）。
/// - 本机运行时的登录状态（`runtimes`）只在启用、换运行时与大脑起不来时查（状态命令慢）；还没查过为 nil。
/// - 通知只推"等你"（带选项的 Cue 消息）与 urgent 的 Cue 消息，只由值班的这台 Mac 判断：你没在看 Cue 页时，这台 Mac 发本机通知
///   （算"等你"那种提示，开关与提示音在设置里），并给消息置推送标志（`CueStore.flagCueMessageForPush`），手机由服务端订阅推送（见 `AlertSubscriptions`）。
///   免打扰只认系统的专注模式，不看打扰时段（那只管 Cue 自己巡视，`CueTiming.quietHours`）。
@Observable
final class CueService {
    /// 值班时 Cue 此刻的样子（管理器说了算）；不在这台 Mac 值班为 nil，界面按库推（`CuePresence.derive`）。
    private(set) var state: CuePresence?
    /// 本机能当大脑的运行时（装了且登录了），按启用时的挑选顺序；`refreshRuntimes()` 刷新。
    private(set) var runtimes: [AgentKind]?

    @ObservationIgnored private let store: CueStore
    @ObservationIgnored private let sync: (any SyncControlling)?
    @ObservationIgnored private let hostID: String
    @ObservationIgnored private let library: URL
    @ObservationIgnored private let piAgentDirectory: URL
    @ObservationIgnored private let dependencies: CueDependencies
    @ObservationIgnored private var duty: (shift: Shift, keeper: CueKeeper, task: Task<Void, Never>)?
    /// 上次看到的设置里的运行时：变了就重新查本机的运行时
    @ObservationIgnored private var lastRuntime: Open<AgentKind>?
    private static let log = Logger(subsystem: AppServices.bundleID, category: "cue")

    /// 换了就要新班次的设置。
    private struct Shift: Equatable {
        var name: String
        var runtime: Open<AgentKind>
        var model: String?
        var effort: Open<PiThinkingLevel>?
    }

    init(store: CueStore, sync: (any SyncControlling)?, hostID: String, library: URL, piAgentDirectory: URL, dependencies: CueDependencies) {
        self.store = store
        self.sync = sync
        self.hostID = hostID
        self.library = library
        self.piAgentDirectory = piAgentDirectory
        self.dependencies = dependencies
    }

    enum EnableError: LocalizedError {
        case noRuntime
        var errorDescription: String? { "这台 Mac 上没有装好并登录的 Pi、Codex 或 Claude Code" }
    }

    /// 让 Cue 住在这台 Mac 并启用（另一台 Mac 上的会停下）：只改住在哪、启用时刻。选的 Agent 这台用不了才换成第一家能用的，
    /// 模型属于原来那家，一并清掉；强度留着（运行时自己取档）。
    func enable() async throws {
        let available = await refreshRuntimes()
        guard let first = available.first else { throw EnableError.noRuntime }
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

    /// 改设置（名字、运行时、模型、思考强度）并立即上传。
    func update(_ edit: @escaping @Sendable (inout CueProfile) -> Void) async throws {
        try await store.updateCueProfile(edit)
        await sync?.upload(CueProfile.recordID)
    }

    @discardableResult
    func refreshRuntimes() async -> [AgentKind] {
        let found = await dependencies.scan()
        runtimes = found
        return found
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
        state = nil
        let stopping = duty.keeper.stop(), task = duty.task
        return {
            await stopping()
            await task.value
        }
    }

    private func apply(_ profile: CueProfile?) async {
        if let runtime = profile?.runtime, let last = lastRuntime, runtime != last {
            Task { await refreshRuntimes() }
        }
        lastRuntime = profile?.runtime ?? lastRuntime
        guard let profile, profile.activeHost == hostID else { return await endDuty() }
        let shift = Shift(name: profile.name, runtime: profile.runtime, model: profile.model, effort: profile.effort)
        guard duty?.shift != shift else { return }
        await endDuty()
        let keeper = CueKeeper(
            CueKeeper.Setup(
                store: store, profile: profile, launch: { [launch = dependencies.launch, store] in await launch($0, store) },
                startFailed: { [weak self] in Task { await self?.refreshRuntimes() } }, helper: dependencies.helper, library: library,
                piAgentDirectory: piAgentDirectory, directory: library.appending(path: "Cue", directoryHint: .isDirectory), timing: dependencies.timing)
        ) { [weak self] in self?.state = $0 }
        state = keeper.presence
        duty = (shift, keeper, Task { await keeper.run() })
    }

    private func endDuty() async {
        guard let duty else { return }
        self.duty = nil
        duty.keeper.stop()
        await duty.task.value
        state = nil
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
                let alert = CueAlert.content(name: name, text: message.text, choices: message.choices)
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
