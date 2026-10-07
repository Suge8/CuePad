import CueStore
import Foundation
import Testing
@testable import CuePad

/// 做完了但你还没看（有新回复）：Pi 停在空闲，且停下晚于本机最后一次看这个会话；没看过的从启用这条规则起算。
/// 看过后是"待你回复"，与弹窗问题的"等你确认"分开。列表、项目状态点、Mac 侧栏共用这一条。
@MainActor
struct PiUnreadTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

    private func session(_ state: PiWorkState, since: TimeInterval, id: String = "s", project: UUID? = nil) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: project, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: at(since), busySince: nil, createdAt: at(0), modifiedAt: at(0))
    }

    @Test func 停下晚于最后一次看是有新回复_看过后不是() {
        let done = session(.settled, since: 100)
        #expect(PiUnread.isUnread(done, seen: nil, since: at(50)))
        #expect(PiUnread.isUnread(done, seen: at(90), since: at(50)))
        #expect(!PiUnread.isUnread(done, seen: at(150), since: at(50)))
    }

    @Test func 只有停在空闲才算_规则启用前就停下的不算() {
        for state in [PiWorkState.thinking, .tool, .waitingForUser, .error, .ended] {
            #expect(!PiUnread.isUnread(session(state, since: 100), seen: nil, since: at(50)))
        }
        #expect(!PiUnread.isUnread(session(.settled, since: 10), seen: nil, since: at(50)))
    }

    @Test func 三种说法分开_有新回复_待你回复_等你确认() {
        #expect(PiShown(state: .known(.settled), unread: true).label == "有新回复")
        #expect(PiShown(state: .known(.settled), unread: false).label == "待你回复")
        #expect(PiShown(state: .known(.waitingForUser), unread: false).label == "等你确认")
    }

    @Test func 项目状态点_等你确认与出错之后是有新回复_再是工作中() {
        let project = UUID()
        let working = session(.thinking, since: 100, id: "w", project: project)
        let done = session(.settled, since: 100, id: "d", project: project)
        func byProject(_ sessions: [PiSessionState]) -> [UUID: PiShown] {
            PiSessionListItem.byProject(sessions.map { PiSessionListItem(state: $0) }) { PiShown(state: $0.state.state, unread: $0.state.sessionID == "d") }
        }
        #expect(byProject([working, done])[project] == PiShown(state: .known(.settled), unread: true))

        let asking = session(.waitingForUser, since: 100, id: "q", project: project)
        #expect(byProject([working, done, asking])[project]?.state == .known(.waitingForUser))
    }

    @Test func 看过记在本机偏好_退出再回来还算看过() {
        let suite = "seen-\(UUID())"
        let done = session(.settled, since: Date.now.timeIntervalSince1970 + 60)
        let settings = AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:])
        #expect(settings.isUnread(done))

        settings.markSeen(done, at: at(Date.now.timeIntervalSince1970 + 120))

        #expect(!settings.isUnread(done))
        #expect(!AppSettings(defaults: UserDefaults(suiteName: suite)!, launchArguments: [:]).isUnread(done))
    }
}
