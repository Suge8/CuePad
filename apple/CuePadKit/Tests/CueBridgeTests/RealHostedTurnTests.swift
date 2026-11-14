#if os(macOS)
import CueStore
import CueTestSupport
import Foundation
import Testing
@testable import CueBridge

/// 托管会话的一轮，每家一样（`HostedTurns`）。
@MainActor
@Suite(RealAgents.tiered, .enabled(if: Hosting.uncovered == nil || PinnedAgent.fullMatrix, Comment(rawValue: Hosting.uncovered ?? "")))
struct RealHostedTurnTests {
    /// 在跑时再说一句：停下在跑的、以这句开新的一轮，两轮之间不报歇下（不多响一次"做完了"），这句答完才歇下。
    @Test(arguments: Hosting.allCases)
    func aMessageDuringATurnStartsTheNextWithoutSettlingBetween(_ hosting: Hosting) async throws {
        try await EndRig.run(hosting, timing: .system) { rig in
            rig.hang("BUSY-HANG")
            let id = try await rig.open()
            try await rig.bridge.send(SessionMessage(text: "BUSY-HANG first"), to: id)
            try await eventually("这一轮在跑、停在模型里") { rig.asked("BUSY-HANG first") && rig.bridge.session(id: id)?.state.isWorking == true }
            let log = ChangeLog(rig.bridge)
            _ = try await rig.converse("NEXT", in: id)
            try await eventually("这句答完歇下") { log.settles > 0 && rig.bridge.session(id: id)?.state == .settled }
            #expect(log.settles == 1, "\(log.states)")
        }
    }
}
#endif
