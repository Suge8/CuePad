#if os(macOS)
import CueStore
import CueText
import Foundation
import Observation
import UserNotifications
import os

/// Cue 在这台 Mac 上的样子（`CueService.state`）。
enum CueState: Equatable {
    /// 没启用，或住在别的 Mac
    case asleep
    case idle
    /// 在跑一轮
    case thinking
    /// 起不来（原因）；你的下一条消息会让它再试
    case failed(String)
}

/// 管理器的外部依赖；`MacDependencies.cue` 给出，测试换成替身。
struct CueDependencies {
    /// 查本机装了且登录了的运行时（生产是 `CueRuntimes.scan`，慢）
    var scan: @Sendable () async -> [CueRuntimeOption]
    /// 起大脑前找可执行文件等（生产是 `CueRuntimes.launch`，不问登录）
    var launch: @Sendable (CueRuntime) async -> CueLaunch?
    /// App 里的 `cuepad` 命令行：Cue 的 MCP 服务
    var helper: URL
    var notifier: any CueNotifying
    var timing = CueTiming()
}

/// Cue 的通知（Mac 本机）。点开时调 `onOpen`。
protocol CueNotifying: AnyObject {
    var onOpen: (() -> Void)? { get set }
    func post(id: UUID, title: String, body: String) async
}

/// Mac 上的 Cue：界面的唯一接口（`services.cue`）。手机与别的 Mac 不跑这里，界面直接读写库（`cueProfile` 等）。
/// - 启用：按 `CueRuntimes.order` 选第一家装了且登录了的运行时，写 `cueProfile`（住这台 Mac、默认模型、低思考强度）；
///   另一台 Mac 启用就是接管，这台看到 `hostID` 变了就停下。停用只清 `enabledAt`。
/// - Cue 住在这台 Mac 且已启用时起一个 `CueKeeper` 值班；名字、运行时、模型、强度变了就换一个（新班次）。
/// - 本机运行时的登录状态（`runtimes`）只在启用、换运行时与大脑起不来时重新查（状态命令慢）。
/// - 通知只推"等你"（带选项的 Cue 消息）与 urgent 的 Cue 消息，只由值班的这台 Mac 判断：Cue 页没开着、本地 8–23 点之间，
///   这台 Mac 发本机通知，并给消息置推送标志（`CueStore.flagCueMessageForPush`），手机由服务端订阅推送（见 `AlertSubscriptions`）。
@Observable
final class CueService {
    private(set) var state: CueState = .asleep
    /// 本机能当大脑的运行时（装了且登录了），按启用时的挑选顺序；`refreshRuntimes()` 刷新。
    private(set) var runtimes: [CueRuntime] = []
    /// 开着的 Cue 页数：Cue 页出现时加一、消失时减一。大于 0 时不推通知。
    var pageViewers = 0
    /// 点开了 Cue 的通知：界面打开 Cue 页后调 `consumeOpen()`。
    private(set) var pendingOpen = false

    @ObservationIgnored private let store: CueStore
    @ObservationIgnored private let hostID: String
    @ObservationIgnored private let library: URL
    @ObservationIgnored private let piAgentDirectory: URL
    @ObservationIgnored private let dependencies: CueDependencies
    @ObservationIgnored private var duty: (shift: Shift, keeper: CueKeeper, task: Task<Void, Never>)?
    /// 上次看到的设置里的运行时：变了就重新查本机的运行时
    @ObservationIgnored private var lastRuntime: Open<CueRuntime>?
    private static let log = Logger(subsystem: AppServices.bundleID, category: "cue")

    /// 换了就要新班次的设置。
    private struct Shift: Equatable {
        var name: String
        var runtime: Open<CueRuntime>
        var model: String?
        var effort: Open<PiThinkingLevel>?
    }

    init(store: CueStore, hostID: String, library: URL, piAgentDirectory: URL, dependencies: CueDependencies) {
        self.store = store
        self.hostID = hostID
        self.library = library
        self.piAgentDirectory = piAgentDirectory
        self.dependencies = dependencies
    }

    var notifier: any CueNotifying { dependencies.notifier }

    enum EnableError: LocalizedError {
        case noRuntime
        var errorDescription: String? { "这台 Mac 上没有装好并登录的 Pi、Codex 或 Claude Code" }
    }

    /// 让 Cue 住在这台 Mac 并启用（另一台 Mac 上的会停下）。
    func enable() async throws {
        guard let pick = await refreshRuntimes().first else { throw EnableError.noRuntime }
        try await store.updateCueProfile { [hostID] profile in
            profile.hostID = hostID
            profile.runtime = .known(pick.runtime)
            profile.model = nil
            profile.effort = .known(.low)
            profile.enabledAt = .now
        }
    }

    func disable() async throws {
        try await store.updateCueProfile { $0.enabledAt = nil }
    }

    @discardableResult
    func refreshRuntimes() async -> [CueRuntimeOption] {
        let available = await dependencies.scan()
        runtimes = available.map(\.runtime)
        return available
    }

    func requestOpen() { pendingOpen = true }

    func consumeOpen() -> Bool {
        defer { pendingOpen = false }
        return pendingOpen
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

    /// 退出收尾：立即不再值班；返回的等待只停大脑（不在主线程上，见 `AppServices.beginShutdown`）。
    func beginStop() -> @Sendable () async -> Void {
        let brain = duty?.keeper.brain
        duty?.task.cancel()
        duty = nil
        return { await brain?.stop() }
    }

    private func apply(_ profile: CueProfile?) async {
        if let runtime = profile?.runtime, let last = lastRuntime, runtime != last { Task { await refreshRuntimes() } }
        lastRuntime = profile?.runtime ?? lastRuntime
        guard let profile, profile.hostID == hostID, profile.enabledAt != nil else { return await endDuty() }
        let shift = Shift(name: profile.name, runtime: profile.runtime, model: profile.model, effort: profile.effort)
        guard duty?.shift != shift else { return }
        await endDuty()
        let keeper = CueKeeper(
            CueKeeper.Setup(
                store: store, profile: profile, launch: dependencies.launch,
                startFailed: { [weak self] in Task { await self?.refreshRuntimes() } }, helper: dependencies.helper, library: library,
                piAgentDirectory: piAgentDirectory, directory: library.appending(path: "Cue", directoryHint: .isDirectory), timing: dependencies.timing)
        ) { [weak self] in self?.state = $0 }
        state = .idle
        duty = (shift, keeper, Task { await keeper.run() })
    }

    private func endDuty() async {
        guard let duty else { return }
        self.duty = nil
        duty.keeper.stop()
        await duty.task.value
        state = .asleep
    }

    // MARK: 通知

    /// 推"等你"与 urgent 的 Cue 消息，直到任务取消。只推这次启动之后新写的。
    func followNotifications() async throws {
        let since = Date.now
        var seen = Set<UUID>()
        for try await messages in store.observe({ try $0.cueMessages(limit: 20) }) {
            let fresh = messages.filter {
                $0.author == .known(.cue) && $0.createdAt >= since && ($0.choices != nil || $0.urgent) && !seen.contains($0.id)
            }
            seen.formUnion(fresh.map(\.id))
            guard duty != nil, pageViewers == 0, !dependencies.timing.quietHours.contains(Calendar.current.component(.hour, from: .now)) else { continue }
            let name = (try? await store.cueProfile())?.name
            for message in fresh {
                let alert = CueAlert.content(name: name, text: message.text, choices: message.choices)
                await dependencies.notifier.post(id: message.id, title: alert.title, body: alert.body)
                do {
                    try await store.flagCueMessageForPush(message.id)
                } catch {
                    Self.log.error("Cue 消息没能标上手机推送：\(error.localizedDescription, privacy: .public)")
                }
            }
        }
    }
}

/// 系统通知中心（UserNotifications）。第一次推之前请求权限。
final class SystemCueNotifier: NSObject, CueNotifying, UNUserNotificationCenterDelegate {
    var onOpen: (() -> Void)?
    private var authorized: Bool?

    override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    func post(id: UUID, title: String, body: String) async {
        let center = UNUserNotificationCenter.current()
        do {
            if authorized == nil { authorized = try await center.requestAuthorization(options: [.alert, .sound]) }
            guard authorized == true else { return }
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.sound = .default
            try await center.add(UNNotificationRequest(identifier: id.uuidString, content: content, trigger: nil))
        } catch {
            Logger(subsystem: AppServices.bundleID, category: "cue").error("Cue 的通知没能发出：\(error.localizedDescription, privacy: .public)")
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        onOpen?()
    }

    /// App 在前台也显示：Cue 页没开着才会推到这里。
    func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions { [.banner, .sound] }
}

/// 隔离库（开发与验收）不发系统通知：通知权限按 bundle id 记，与正式版同一个。只记日志。
final class LoggedCueNotifier: CueNotifying {
    var onOpen: (() -> Void)?

    func post(id: UUID, title: String, body: String) async {
        Logger(subsystem: AppServices.bundleID, category: "cue").notice("Cue 通知（隔离库不发）：\(title, privacy: .public)：\(body, privacy: .private)")
    }
}
#endif
