#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 侧栏 Pi 分组的会话顺序：与 iOS 的 Agent 页同序，已结束的接在后面、不重复、有上限。
struct PiSidebarTests {
    private func session(_ id: String, _ state: PiWorkState) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now,
            modifiedAt: .now)
    }

    @Test func 在线按要你注意的先后_本机实时优先于同步记录_已结束接在后面不重复且最多五行() {
        let live = [session("idle", .settled), session("wait", .waitingForUser)]
        // 会话列表查询的顺序：未结束的在前，再是已结束的，各自从新到旧
        let recorded = [
            session("idle", .tool), session("tool", .tool), session("err", .error),
            session("e1", .ended), session("wait", .ended), session("e2", .ended), session("e3", .ended), session("e4", .ended),
            session("e5", .ended), session("e6", .ended),
        ]

        let rows = PiSessionState.sidebarRows(live: live, recorded: recorded, pastLimit: 5)

        #expect(rows.map(\.sessionID) == ["wait", "err", "tool", "idle", "e1", "e2", "e3", "e4", "e5"])
        #expect(rows.first { $0.sessionID == "idle" }?.state == .known(.settled))
    }
}
#endif
