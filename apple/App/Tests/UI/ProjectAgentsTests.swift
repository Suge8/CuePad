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
        #expect(ProjectAgents.sharedHost(rows) == nil)  // 在不同的地方：各行自己写
    }

    @Test func 会话都在同一台别的Mac上时_那台Mac只在栏标题上写一次() {
        let studio = DirectoryBinding(
            id: UUID(), projectID: project, hostID: "studio", hostName: "工作室的 Mac Studio", folder: "app", createdAt: .now, modifiedAt: .now)
        let rows = ProjectAgents.rows(
            live: [], recorded: [session("a", .tool, host: "studio"), session("b", .waitingForUser, host: "studio")], bindings: [studio], host: "this")

        #expect(ProjectAgents.sharedHost(rows) == "工作室的 Mac Studio")
        #expect(ProjectAgents.sharedHost(ProjectAgents.rows(live: [session("c", .tool, host: "this")], recorded: [], bindings: [], host: "this")) == nil)
    }
}
#endif
