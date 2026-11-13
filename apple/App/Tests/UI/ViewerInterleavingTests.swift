import CueStore
import Foundation
import Testing
@testable import CuePad

/// 这台设备有人在看哪些页只由 `ViewerKeeper` 算：几个窗口的导航、前后台、Cue 页出现消失随意交错，
/// 它给的始终是各个前台窗口导航最上面的会话页之和，Cue 页任一处在看才算；收回只收自己的，重复收回不多减。
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

    @Test(arguments: [1, 7, 42, 1_000, 31_337] as [UInt64])
    func 窗口导航前后台与Cue页随意交错_在看的始终是前台窗口最上面的页(seed: UInt64) {
        var random = SplitMix(seed)
        let keeper = app.services.viewer
        let sessions: [Route] = ["atlas", "beacon", "comet"].map { .session($0) }
        var windows = [Window(app.services)]

        for step in 0..<400 {
            let window = windows[Int(random.next() % UInt64(windows.count))]
            switch random.next() % 8 {
            case 0 where windows.count < 3:
                windows.append(Window(app.services))
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
                guard let token = window.cues.keys.randomElement(using: &random) else { continue }
                window.cues[token] = nil
                keeper.showCue(false, by: token)
                keeper.showCue(false, by: token)  // 页拆掉时 onDisappear 与 onChange 都可能报一次
            case 6:
                guard let token = window.cues.keys.randomElement(using: &random) else { continue }
                window.cues[token]?.toggle()
            default:
                window.workspace.show(sessions[Int(random.next() % 3)])
            }
            windows.forEach { $0.report(to: keeper) }

            let shown = windows.filter(\.foreground)
            let expected = ViewerKeeper.Viewing(
                sessions: Set(shown.flatMap(\.workspace.shownSessions)), cue: shown.contains { $0.cues.values.contains(true) })
            #expect(keeper.viewing == expected, "seed \(seed) 第 \(step) 步")
            #if os(iOS)
            let services: AppServices = app.services
            #expect(services.pollingCadence == .phone(hasOpenDeliveries: false, isWatching: !expected.isEmpty, doorbell: services.doorbellFallback))
            #endif
        }

        windows.forEach { $0.close(from: keeper) }
        #expect(keeper.viewing.isEmpty)
    }
}

private struct SplitMix: RandomNumberGenerator {
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
