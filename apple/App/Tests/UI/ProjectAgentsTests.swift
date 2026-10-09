#if os(macOS)
import CueStore
import Foundation
import Testing
@testable import CuePad

/// Mac 项目页的 Agent 栏与侧栏读同一份"现在"：本机桥上的会话与别的 Mac 同步来的在线会话一起列，按要你注意的先后；
/// 别的 Mac 上的写明在哪台 Mac 上；已结束的不列。
struct ProjectAgentsTests {
    private let project = UUID()

    private func session(_ id: String, _ state: PiWorkState, host: String) -> PiSessionState {
        PiSessionState(
            id: UUID(), sessionID: id, hostID: host, title: id, projectID: project, state: .known(state), detail: nil, folder: nil,
            lastPrompt: nil, lastReply: nil, question: nil, notify: nil, stateSince: .now, busySince: nil, createdAt: .now,
            modifiedAt: .now)
    }

    @Test func 本机与别的Mac上在线的会话都列_别的Mac上的写在哪台Mac上_已结束的不列() {
        let air = DirectoryBinding(id: UUID(), projectID: project, hostID: "air", hostName: "MacBook Air", folder: "app", createdAt: .now, modifiedAt: .now)

        let rows = ProjectAgents.rows(
            live: [session("local", .tool, host: "this")],
            recorded: [session("remote", .waitingForUser, host: "air"), session("gone", .ended, host: "air"), session("other", .tool, host: "studio")],
            bindings: [air], host: "this")

        #expect(rows.map(\.state.sessionID) == ["remote", "local", "other"])
        #expect(rows.map(\.hostName) == ["MacBook Air", nil, "另一台 Mac"])
    }
}
#endif
