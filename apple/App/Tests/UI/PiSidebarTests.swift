#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 侧栏 Pi 分组的会话顺序：与 iOS 的 Pi 页同序，已结束与历史接在后面、不重复、有上限。
struct PiSidebarTests {
    private func session(_ id: String, _ state: PiWorkState) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now,
            modifiedAt: .now)
    }

    @Test func 在线按要你注意的先后_其后已结束再历史_同一会话只出现一次_过去的最多五行() {
        let live = [session("idle", .settled), session("wait", .waitingForUser), session("tool", .tool), session("err", .error)]
        let ended = [session("e1", .ended), session("idle", .ended), session("e2", .ended)]
        let history = ["e2", "h1", "wait", "h2", "h3", "h4"].map { session($0, .ended) }

        let rows = PiSessionState.sidebarRows(live: live, ended: ended, history: history, pastLimit: 5)

        #expect(rows.map(\.sessionID) == ["wait", "err", "tool", "idle", "e1", "e2", "h1", "h2", "h3"])
    }
}
#endif
