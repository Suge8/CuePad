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

nonisolated struct CueLaunch: Equatable, Sendable {
    var executable: URL
    /// 给大脑与 MCP 服务的 PATH（`ExecutableLocator.system`）：App 自己的 PATH 很短，运行时起的 node 等靠它找到。
    var path: String
    /// 开会话能用的 Agent 与模型（`CuePrompt.system` 的 `agents`）
    var agents: [MacAgent]

    /// 这台 Mac 上起大脑：`executable` 是这家检测时挑中的可执行文件（`AgentStatus.executable`，没装为 nil 就起不了），不问登录
    /// （登录不了大脑起不来或一轮出错，由管理器报出）；能用的 Agent 与模型是这台 Mac 写下的那条（`CueStore.macAgents`）。
    @concurrent static func local(executable: URL?, store: CueStore, host: String) async throws -> CueLaunch? {
        guard let executable else { return nil }
        return CueLaunch(executable: executable, path: await ExecutableLocator.system.path, agents: try await store.macAgents(on: host).agents)
    }
}

/// Cue 的通知出口（Mac 本机）：生产是 `AlertCenter`（你在不在看、点开去哪、开关、提示音、前台怎么呈现都在那里），测试换成记录型替身。
protocol CueNotifying: AnyObject {
    func post(title: String, body: String) async
}

/// Mac 上的 Cue：界面的唯一接口（`services.cue`）。手机与别的 Mac 不跑这里，界面直接读写库（`cueProfile` 等）。
/// - 启用、停用不经这里：两端同一个入口（`AppServices.enableCue(on:)`、`updateCue`，规则在 `CueStore.enableCue`）；
///   另一台 Mac 启用就是接管，这台看到 `activeHost` 不是自己就停下。
/// - `activeHost` 是这台时起一个 `CueKeeper` 值班，不是就停掉；名字、运行时、模型、强度变了由值班的它自己对上（就地换或换大脑）。
/// - 通知：哪几条要提示你只在 `CueMessage.alerts`；手机推送标志在写下时就置好（`CueStore.insertCueMessage`），这里只给值班的这台 Mac
///   发本机通知（算"等你"那种提示，开关、提示音与你在不在看都在 `AlertCenter`）。免打扰只认系统的专注模式，不看打扰时段（那只管 Cue 自己巡视，`CueTiming.quietHours`）。
@Observable
final class CueService {
    /// Cue 在这台 Mac 值班（同步据此按节奏拉取，见 `AppServices.pollingCadence`）。
    var onDuty: Bool { duty != nil }
    /// 在这台 Mac 值班的管理器：Cue 页的"运行情况"读它的经过与上下文；不在这里值班为 nil。
    var keeper: CueKeeper? { duty?.keeper }
    @ObservationIgnored private let setup: CueKeeper.Setup
    @ObservationIgnored private let hostID: String
    @ObservationIgnored private let notifier: any CueNotifying
    private var duty: (keeper: CueKeeper, task: Task<Void, Never>)?
    private var store: CueStore { setup.recorder.store }
    private nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "cue")

    /// Cue 此刻的样子经 `recorder` 写（与会话状态同一个节拍、同一条落盘链），资料库与本机 id 也取它的。
    init(recorder: PiStateRecorder, sync: (any SyncControlling)?, library: URL, piAgentDirectory: URL, dependencies: CueDependencies) {
        let store = recorder.store
        setup = CueKeeper.Setup(
            recorder: recorder, launch: { [launch = dependencies.launch] in try await launch($0, store) }, helper: dependencies.helper,
            library: library, piAgentDirectory: piAgentDirectory, timing: dependencies.timing,
            upload: { [sync] ids in await sync?.upload(ids) }, fetchFile: { [sync] key in try await sync.fetchFile(key) })
        hostID = recorder.hostID
        notifier = dependencies.notifier
    }

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
        let stopping = duty.keeper.stop(), task = duty.task, recorder = setup.recorder
        return {
            await stopping()
            await Self.rest(recorder)
            await task.value
        }
    }

    private func apply(_ profile: CueProfile?) async {
        guard profile?.activeHost == hostID else { return await endDuty() }
        guard duty == nil else { return }
        let keeper = CueKeeper(setup)
        duty = (keeper, Task { await keeper.run() })
    }

    private func endDuty() async {
        guard let duty else { return }
        self.duty = nil
        duty.keeper.stop()
        await duty.task.value
        await Self.rest(setup.recorder)
    }

    /// 不再值班：库里写回歇着（立即写、丢掉挂起的那一步），别的设备不会一直看到它在想（不在主线程上等，退出收尾时也能写）。
    private nonisolated static func rest(_ recorder: PiStateRecorder) async {
        do {
            try await recorder.updateCue(.settled)
        } catch {
            log.error("Cue 歇着没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: 通知

    /// 值班时给要提示你的 Cue 消息（`CueMessage.alerts`）发本机通知，直到任务取消。只发这次启动之后新写的。
    func followNotifications() async throws {
        let since = Date.now
        var seen = Set<UUID>()
        for try await messages in store.observe({ try $0.cueMessages(limit: 20) }) {
            let fresh = messages.filter { $0.alerts && $0.createdAt >= since && !seen.contains($0.id) }
            seen.formUnion(fresh.map(\.id))
            guard duty != nil, !fresh.isEmpty else { continue }
            let name = try await store.cueProfile()?.name
            for message in fresh {
                let alert = CueAlert.content(name: name, text: message.text, asking: message.asking, choices: message.shownChoices, looks: message.shots.map(\.look))
                await notifier.post(title: alert.title, body: alert.body)
            }
        }
    }
}
#endif
