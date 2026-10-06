#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// ⌘K 的"会话"范围：上面"现在"是在线的、要你注意的在前；下面是已结束的，按结束时间分段（与手机 Agent 页同一规则），
/// 下一页只接在末段之后。需求变更：取代按项目分组（按项目分组时，下一页会插进上面的组）。
struct SessionSearchTests {
    let now = WallTests.date(2026, 10, 7, hour: 10)

    private func session(_ id: String, _ state: PiWorkState, at date: Date? = nil) -> PiSessionState {
        let since = date ?? now
        return PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: nil, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: since, busySince: nil, createdAt: since,
            modifiedAt: since)
    }

    @Test func 现在按要你注意的先后_已结束按结束时间分段() {
        let live = [session("s1", .tool), session("s2", .waitingForUser)]
        let ended = [
            session("e1", .ended, at: WallTests.date(2026, 10, 7, hour: 8)), session("e2", .ended, at: WallTests.date(2026, 10, 6)),
            session("e3", .ended, at: WallTests.date(2026, 10, 6, hour: 8)), session("e4", .ended, at: WallTests.date(2026, 9, 1)),
        ]

        let groups = SessionGroup.grouped(live: live, ended: ended, now: now, calendar: WallTests.calendar)

        #expect(groups.map(\.key) == [.now, .ended(.today), .ended(.yesterday), .ended(.earlier)])
        #expect(groups.map { $0.sessions.map(\.sessionID) } == [["s2", "s1"], ["e1"], ["e2", "e3"], ["e4"]])
    }

    @Test func 没有在线会话时不留空的现在() {
        let groups = SessionGroup.grouped(live: [], ended: [session("e1", .ended)], now: now, calendar: WallTests.calendar)
        #expect(groups.map(\.key) == [.ended(.today)])
    }
}
#endif
