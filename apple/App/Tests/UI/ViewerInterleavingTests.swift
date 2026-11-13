import CueSync
@testable import CueStore
import Foundation
import Synchronization
import Testing
@testable import CuePad

/// 这台设备有人在看哪些页只由 `ViewerKeeper` 算：几个窗口的导航、前后台、Cue 页出现消失随意交错，
/// 它给的始终是各个前台窗口导航最上面的会话页之和，Cue 页任一处在看才算；收回只收自己的，重复收回不多减；
/// 上传慢、时成时败也不乱：停下来之后库里那条就是此刻在看的。
@Suite(.releasesLibraries)
struct ViewerInterleavingTests {
    let app = TestApp()

    /// 一个窗口：各自的导航与前后台，里面出现过的 Cue 页（标记 → 在不在看）。报法照 `SessionViewing` 与 `CueViewing`。
    @MainActor private final class Window {
        let id = UUID()
        let workspace: Workspace
        var foreground = true
        var cues: [UUID: Bool] = [:]
        init(_ services: AppServices) { workspace = Workspace(services: services) }

        func report(to keeper: ViewerKeeper) {
            keeper.show(foreground ? workspace.shownSessions : [], in: id)
            for (token, on) in cues { keeper.showCue(on && foreground, by: token) }
        }

        func close(from keeper: ViewerKeeper) {
            keeper.show([], in: id)
            for token in cues.keys { keeper.showCue(false, by: token) }
        }
    }

    @Test(arguments: 0..<40 as Range<UInt64>)
    func 窗口导航前后台与Cue页随意交错_在看的始终是前台窗口最上面的页(seed: UInt64) {
        var random = SplitMix(seed)
        var windows = [Window(app.services)]
        for step in 0..<400 {
            let expected = Self.step(&random, &windows, app.services, keeper: app.services.viewer)
            #expect(app.services.viewer.viewing == expected, "seed \(seed) 第 \(step) 步")
            #if os(iOS)
            let services: AppServices = app.services
            #expect(services.pollingCadence == .phone(hasOpenDeliveries: false, isWatching: !expected.isEmpty, doorbell: services.doorbellFallback))
            #endif
        }
        windows.forEach { $0.close(from: app.services.viewer) }
        #expect(app.services.viewer.viewing.isEmpty)
    }

    @Test(arguments: 0..<12 as Range<UInt64>)
    func 上传时慢时快时成时败_停下后库里那条就是此刻在看的(seed: UInt64) async throws {
        var random = SplitMix(seed)
        let device = "probe-\(seed)", store = app.services.store
        let sync = FlakySync(seed: seed)
        #if os(macOS)
        let keeper = ViewerKeeper(store: store, sync: sync, device: device, idleSeconds: { 0 })  // 人一直在跟前
        #else
        let keeper = ViewerKeeper(store: store, sync: sync, device: device)
        #endif
        let keeping = Task { try await keeper.keep() }
        defer { keeping.cancel() }
        var windows = [Window(app.services)]
        for _ in 0..<80 {
            _ = Self.step(&random, &windows, app.services, keeper: keeper)
            if random.next() % 3 == 0 { try await Task.sleep(for: .milliseconds(random.next() % 4)) }
        }
        let settled = keeper.viewing
        try await eventually("库里那条跟上此刻在看的") {
            let stored = try await store.viewer(device)
            return Set(settled.sessions.compactMap(\.sessionID)) == stored?.sessionIDs ?? [] && settled.cue == stored?.cue ?? false
        }
        #expect(sync.failures > 0, "seed \(seed)：失败注入到了")
    }

    /// 随机做一件事（开关窗口、切前后台、导航、Cue 页出现消失与切换），各窗口照界面的报法报给 `keeper`；返回此刻应当在看的。
    private static func step(_ random: inout SplitMix, _ windows: inout [Window], _ services: AppServices, keeper: ViewerKeeper) -> ViewerKeeper.Viewing {
        let sessions: [Route] = ["atlas", "beacon", "comet"].map { .session($0) }
        let window = windows[Int(random.next() % UInt64(windows.count))]
        switch random.next() % 8 {
        case 0 where windows.count < 3:
            windows.append(Window(services))
        case 1 where windows.count > 1:
            windows.removeAll { $0 === window }
            window.close(from: keeper)
        case 2:
            window.foreground.toggle()
        case 3:
            window.workspace.show(.project(Project.defaultID))
        case 4:
            window.cues[UUID()] = true
        case 5:
            if let token = window.cues.keys.sorted(by: { $0.uuidString < $1.uuidString }).randomElement(using: &random) {
                window.cues[token] = nil
                keeper.showCue(false, by: token)
                keeper.showCue(false, by: token)  // 页拆掉时 onDisappear 与 onChange 都可能报一次
            }
        case 6:
            if let token = window.cues.keys.sorted(by: { $0.uuidString < $1.uuidString }).randomElement(using: &random) { window.cues[token]?.toggle() }
        default:
            window.workspace.show(sessions[Int(random.next() % 3)])
        }
        windows.forEach { $0.report(to: keeper) }
        let shown = windows.filter(\.foreground)
        return ViewerKeeper.Viewing(
            sessions: Set(shown.flatMap(\.workspace.shownSessions)), cue: shown.contains { $0.cues.values.contains(true) })
    }
}

/// 上传按种子随机慢 0–20 毫秒，第一次与约三成失败。
private nonisolated final class FlakySync: SyncControlling {
    private let state: Mutex<(random: SplitMix, attempts: Int, failures: Int)>
    init(seed: UInt64) { state = Mutex((SplitMix(seed &+ 1), 0, 0)) }
    var attempts: Int { state.withLock { $0.attempts } }
    var failures: Int { state.withLock { $0.failures } }

    func send(recordNames: Set<String>) async -> Bool {
        let (delay, fails) = state.withLock { state in
            let roll = state.random.next()
            state.attempts += 1
            let fails = state.attempts == 1 || roll % 10 < 3
            if fails { state.failures += 1 }
            return (roll % 21, fails)
        }
        try? await Task.sleep(for: .milliseconds(delay))
        return !fails
    }
    var stateUpdates: AsyncStream<SyncState> { AsyncStream { _ in } }
    func start() async {}
    func stop() async {}
    func syncNow() async throws -> SyncPullResult { .noData }
    func push() async {}
    func activated() async {}
    func resolve(_ resolution: SyncResolution) async throws {}
    var fileTransfers: AsyncStream<[String: FileTransfer]> { AsyncStream { _ in } }
    func fetchFile(_ key: String) async throws -> URL { throw FileFetchFailure.notSyncing }
}

private extension CueStore {
    func viewer(_ device: String) throws -> Viewer? { try select(Viewer.self, where: "device = ?", [device]).first }
}

private nonisolated struct SplitMix: RandomNumberGenerator, Sendable {
    var state: UInt64
    init(_ seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
