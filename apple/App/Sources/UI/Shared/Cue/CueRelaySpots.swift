import QuartzCore
import SwiftUI

nonisolated struct RelayEnd: Equatable, Sendable {
    var session: String
    var task: UUID?
    var opens = false
}

enum CueSpot: Int {
    case entry
    case header
}

enum EndSpot: Equatable {
    case session(String, Row)
    case task(UUID, session: String?)

    enum Row: Int {
        case rail = 0
        case own = 1
        case task
    }

    func rank(for end: RelayEnd) -> Int? {
        switch self {
        case .session(let session, let row): session == end.session ? row.rawValue : nil
        case .task(let task, let session): task == end.task || session == end.session ? Row.task.rawValue : nil
        }
    }
}

extension View {
    /// 这次交给刚开出这个会话时，状态标先透明着，光落下时才亮出来（同 `relayArrival`）。
    func relaySpot(session: String?, row: EndSpot.Row = .own) -> some View { modifier(SessionSpot(session: session, row: row)) }

    func relaySpot(task: UUID) -> some View { modifier(TaskSpot(task: task)) }

    func relaySpot(cue spot: CueSpot) -> some View { background { RelayAnchor(role: .cue(spot)) } }

    func relayArrival(session: String) -> some View { modifier(Arrival(session: session)) }
}

extension EnvironmentValues {
    @Entry var relayStage: CueRelayStage.Stage?
}

/// 起飞与接住共用参与判定，不在窗口根上改环境值。
private struct SessionSpot: ViewModifier {
    let session: String?
    let row: EndSpot.Row
    @Environment(Workspace.self) private var workspace
    @Environment(\.pageActive) private var active

    func body(content: Content) -> some View {
        let flying = session.flatMap { workspace.relays(session: $0) ? $0 : nil }
        content.modifier(Arrival(session: session)).background {
            if active, let flying { RelayAnchor(role: .end(.session(flying, row))).transition(.identity) }
        }
    }
}

private struct TaskSpot: ViewModifier {
    let task: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(\.cardAgents) private var agents

    func body(content: Content) -> some View {
        let session = agents.items[task]?.state.sessionID
        let flying = workspace.relays(session: session, task: task)
        content.background {
            if flying { RelayAnchor(role: .end(.task(task, session: session))).transition(.identity) }
        }
    }
}

/// 藏起来是当场的，不淡出。
private struct Arrival: ViewModifier {
    let session: String?
    @Environment(\.relayStage) private var stage

    func body(content: Content) -> some View {
        let waits = session.map { stage?.arriving.contains($0) == true } == true
        content
            .opacity(waits ? 0 : 1)
            .animation(waits ? nil : Motion.fade, value: waits)
    }
}

extension Workspace {
    func relays(session: String?, task: UUID? = nil) -> Bool {
        let live = services.liveSessions
        return session.map { cue.wake?.sessions.contains($0) == true || live.relays(session: $0) } == true
            || task.map { live.relays(task: $0) } == true
    }
}
