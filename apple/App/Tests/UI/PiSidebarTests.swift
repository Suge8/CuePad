#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 侧栏 Agent 区只回答"现在"：只列在线的会话，与 iOS 的 Agent 页同序（需要 /reload 的排在工作中之后），已结束的不列（在"全部会话"里）；
/// 区域固定在侧栏底部、最多露出几行，要你注意的在前，其余收成"还有 N 个"。
struct PiSidebarTests {
    private func session(_ id: String, _ state: PiWorkState) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now,
            modifiedAt: .now)
    }

    @Test func 只列在线的_按要你注意的先后_需要reload在工作中之后_本机实时优先于同步记录_已结束的不列() {
        let live = [session("idle", .settled), session("wait", .waitingForUser)]
        // 会话列表查询的顺序：未结束的在前，再是已结束的，各自从新到旧
        let recorded = [
            session("old", .incompatible), session("idle", .tool), session("tool", .tool), session("err", .error),
            session("e1", .ended), session("wait", .ended), session("e2", .ended), session("e3", .ended), session("e4", .ended),
        ]

        let rows = PiSessionState.liveRows(live: live, recorded: recorded)

        #expect(rows.map(\.sessionID) == ["wait", "err", "tool", "old", "idle"])
        #expect(rows.first { $0.sessionID == "idle" }?.state == .known(.settled))
    }

    @Test func 侧栏Agent区最多露出几行_等你确认与出错在前_其余收成还有N个() {
        let recorded = (0..<7).map { session("w\($0)", .tool) } + [session("wait", .waitingForUser), session("err", .error)]

        let agents = SidebarAgents(rows: PiSessionState.liveRows(live: [], recorded: recorded))

        #expect(agents.visible.count == SidebarAgents.limit)
        #expect(agents.visible.prefix(2).map(\.sessionID) == ["wait", "err"])
        #expect(agents.displayRows.count == SidebarAgents.limit)
        #expect(agents.overflow == recorded.count - SidebarAgents.limit)
    }

    @Test func 多个reload仍然露出三行() {
        let agents = SidebarAgents(rows: [
            session("reload-1", .incompatible), session("reload-2", .incompatible), session("reload-3", .incompatible)
        ])

        #expect(agents.displayRows.count == SidebarAgents.limit)
        #expect(agents.displayRows.allSatisfy {
            if case .session = $0 { true } else { false }
        })
    }

    @Test func 侧栏Agent区行数不超过上限时全露出_没有还有N个() {
        let agents = SidebarAgents(rows: [session("a", .tool), session("b", .settled)])

        #expect(agents.visible.map(\.sessionID) == ["a", "b"])
        #expect(agents.overflow == 0)
    }
}
#endif
