#if os(macOS)
import CueBridge
import CueStore
import CueText
import Foundation
import Observation
import os

struct CueDependencies {
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
    var agents: [MacAgent]

    /// 不问登录：登录不了大脑起不来或一轮出错，由管理器报出。
    @concurrent static func local(executable: URL?, store: CueStore, host: String) async throws -> CueLaunch? {
        guard let executable else { return nil }
        return CueLaunch(executable: executable, path: await ExecutableLocator.system.path, agents: try await store.macAgents(on: host).agents)
    }
}

protocol CueNotifying: AnyObject {
    func post(title: String, body: String) async
}

/// Mac 上的 Cue：界面的唯一接口（`services.cue`）。手机与别的 Mac 不跑这里，界面直接读写库（`cueProfile` 等）。
/// - 启用、停用不经这里（`AppServices.enableCue(on:)`、`updateCue`，规则在 `CueStore.enableCue`）；另一台 Mac 启用就是接管，这台看到 `activeHost` 不是自己就停下。
/// - 通知：哪几条要提示你只在 `CueMessage.alerts`；手机推送标志在写下时就置好（`CueStore.insertCueMessage`），这里只给值班的这台 Mac 发本机通知。
///   免打扰只认系统的专注模式，不看打扰时段（那只管 Cue 自己巡视，`CueTiming.quietHours`）。
@Observable
final class CueService {
    var onDuty: Bool { duty != nil }
    var keeper: CueKeeper? { duty?.keeper }
    @ObservationIgnored private let setup: CueKeeper.Setup
    @ObservationIgnored private let hostID: String
    @ObservationIgnored private let notifier: any CueNotifying
    private var duty: (keeper: CueKeeper, task: Task<Void, Never>)?
    private var store: CueStore { setup.recorder.store }
    private nonisolated static let log = Logger(subsystem: AppIdentity.id, category: "cue")

    /// 与会话状态同一个节拍、同一条落盘链，资料库与本机 id 也取 `recorder` 的。
    init(recorder: StateRecorder, sync: (any SyncControlling)?, library: URL, piAgentDirectory: URL, dependencies: CueDependencies) {
        let store = recorder.store
        setup = CueKeeper.Setup(
            recorder: recorder, launch: { [launch = dependencies.launch] in try await launch($0, store) }, helper: dependencies.helper,
            library: library, piAgentDirectory: piAgentDirectory, timing: dependencies.timing,
            fetchFile: { [sync] key in try await sync.fetchFile(key) })
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
            // 先写的那次歇着是为了退出的时限；值班循环在它之后还会把停之前排着的对账做完、再写此刻（可能挂上合并计时，攥着记录器与资料库），收尾后再歇一次盖过它
            await Self.rest(recorder)
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
    private nonisolated static func rest(_ recorder: StateRecorder) async {
        do {
            try await recorder.updateCue(.settled)
        } catch {
            log.error("Cue 歇着没能写进资料库：\(error.localizedDescription, privacy: .public)")
        }
    }


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
