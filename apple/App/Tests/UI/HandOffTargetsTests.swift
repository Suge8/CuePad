import CueStore
import Foundation
import Testing
@testable import CuePad

/// 任务能交给哪些在线会话：iPhone 的发给 Agent 输入框与 Mac 的发送目标、会话菜单共用 `HandOffTargets`。
struct HandOffTargetsTests {
    let app = TestApp()
    var store: CueStore { app.services.store }

    private func record(_ id: String, host: String, state: PiWorkState = .settled, project: UUID? = nil, agent: AgentKind = .pi) async throws {
        try await PiStateRecorder(store: store, hostID: host).update(sessionID: id, state: state, title: id, directory: id, projectID: project, agent: agent)
    }

    private func live() async throws -> [PiSessionListItem] {
        try await LiveSessions.Page.read(from: store, at: .always()).items.filter { $0.state.state != .known(.ended) }
    }

    @Test func 所有Mac上在线的会话都能交给_已结束的不算() async throws {
        try await record("here", host: "mac-a")
        try await record("there", host: "mac-b")
        try await record("gone", host: "mac-b", state: .ended)

        let ids = HandOffTargets.sessions(try await live(), project: nil, at: .always()).map(\.state.sessionID)

        #expect(Set(ids) == ["here", "there"])
    }

    @Test func 本项目的在前_再按要你注意的先后() async throws {
        let project = try await store.createProject(name: "Work", color: "blue")
        try await record("idle-other", host: "mac-b")
        try await record("asking-other", host: "mac-b", state: .waitingForUser)
        try await record("idle-mine", host: "mac-a", project: project.id)

        let ids = HandOffTargets.sessions(try await live(), project: project.id, at: .always()).map(\.state.sessionID)

        #expect(ids == ["idle-mine", "asking-other", "idle-other"])
    }

    /// 每个会话都写是哪家 Agent，Pi 也写：几家并存时 Pi 不再是不用标的"默认"。
    @Test func 每个会话都写是哪家Agent_Pi也写() async throws {
        for agent in AgentKind.allCases { try await record(agent.rawValue, host: "mac-a", agent: agent) }

        let titles = try await live().map { HandOffTargets.title($0, project: nil, shown: PiShown($0.state, delivery: $0.delivery, at: .always())).parts[1] }

        #expect(Set(titles) == Set(AgentKind.allCases.map(\.name)))
    }
}
