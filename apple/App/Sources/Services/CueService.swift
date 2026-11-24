#if os(macOS)
import CueBridge
import CueStore
import CueText
import Foundation
import Observation
import os

struct CueDependencies {
    var launch: @Sendable (AgentKind, CueStore) async throws -> CueLaunch?
    var helper: URL
    var notifier: any CueNotifying
    var timing = CueTiming()
    /// 每一轮做完交给谁看：只有测试与评测要（它们从这里攒下每一轮的信封与工具调用），正式版不留。
    var finished: (CueRound) -> Void = { _ in }
}

nonisolated struct CueLaunch: Equatable, Sendable {
    var executable: URL
    var path: String
    var agents: [MacAgent]

    @concurrent static func local(executable: URL?, store: CueStore, host: String) async throws -> CueLaunch? {
        guard let executable else { return nil }
        return CueLaunch(executable: executable, path: await ExecutableLocator.system.path, agents: try await store.macAgents(on: host).agents)
    }
}

protocol CueNotifying: AnyObject {
    func post(title: String, body: String) async
}

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

    init(recorder: StateRecorder, sync: (any SyncControlling)?, library: URL, piAgentDirectory: URL, dependencies: CueDependencies) {
        let store = recorder.store
        setup = CueKeeper.Setup(
            recorder: recorder, launch: { [launch = dependencies.launch] in try await launch($0, store) }, helper: dependencies.helper,
            library: library, piAgentDirectory: piAgentDirectory, timing: dependencies.timing,
            fetchFile: { [sync] key in try await sync.fetchFile(key) }, finished: dependencies.finished)
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

    func stop() -> @Sendable () async -> Void {
        guard let duty else { return {} }
        self.duty = nil
        let stopping = duty.keeper.stop(), task = duty.task, recorder = setup.recorder
        return {
            await stopping()
            await Self.rest(recorder)
            await task.value
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
                let alert = CueAlert.content(name: name, text: message.text)
                await notifier.post(title: alert.title, body: alert.body)
            }
        }
    }
}
#endif
