#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 侧栏 Pi 分组的会话顺序：与 iOS 的 Agent 页同序（需要 /reload 的排在工作中之后），已结束的接在后面、不重复、最多 3 行。
struct PiSidebarTests {
    private func session(_ id: String, _ state: PiWorkState) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now,
            modifiedAt: .now)
    }

    @Test func 在线按要你注意的先后_需要reload在工作中之后_本机实时优先于同步记录_已结束接在后面不重复且最多三行() {
        let live = [session("idle", .settled), session("wait", .waitingForUser)]
        // 会话列表查询的顺序：未结束的在前，再是已结束的，各自从新到旧
        let recorded = [
            session("old", .incompatible), session("idle", .tool), session("tool", .tool), session("err", .error),
            session("e1", .ended), session("wait", .ended), session("e2", .ended), session("e3", .ended), session("e4", .ended),
        ]

        let rows = PiSessionState.sidebarRows(live: live, recorded: recorded)

        #expect(rows.map(\.sessionID) == ["wait", "err", "tool", "old", "idle", "e1", "e2", "e3"])
        #expect(rows.first { $0.sessionID == "idle" }?.state == .known(.settled))
    }
}
#endif
