#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// ⌘K 的"会话"范围：结果按项目分组，没绑项目的按文件夹归组、排在项目之后；组内要你注意的在前。
struct SessionSearchTests {
    private func session(_ id: String, _ state: PiWorkState, project: UUID? = nil, folder: String? = nil) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: id, hostID: "mac", title: id, projectID: project, state: .known(state), detail: nil, folder: folder,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now,
            modifiedAt: .now)
    }

    @Test func 按项目分组_文件夹组在项目之后_组内要你注意的在前() {
        let app = UUID(), web = UUID()
        let sessions = [
            session("s1", .tool, project: app), session("s2", .settled, folder: "scratch"), session("s3", .waitingForUser, project: web),
            session("s4", .waitingForUser, project: app), session("s5", .ended, project: app), session("s6", .ended, folder: "scratch"),
            session("s7", .ended),
        ]

        let groups = SessionGroup.grouped(sessions)

        #expect(groups.map(\.key) == [.project(app), .project(web), .folder("scratch"), .folder(nil)])
        #expect(groups.map { $0.sessions.map(\.sessionID) } == [["s4", "s1", "s5"], ["s3"], ["s2", "s6"], ["s7"]])
    }
}
#endif
