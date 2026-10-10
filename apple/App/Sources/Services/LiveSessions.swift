#if os(macOS)
import CuePi
import Observation

/// 桥上在线会话，一个会话一格。`PiBridge.sessions` 是整体被观察的数组：任何一个会话的状态一变，读它的视图全都要重算
/// （会话页、项目页、输入栏的发送菜单……），Agent 多起来时每秒几十次。这里把它拆开：视图读自己那个会话的一格，
/// 只有这个会话自己变了才重算；会话出现、消失才惊动读整张表的视图。以桥为准，不另存状态。
@MainActor @Observable
final class LiveSessions {
    @MainActor @Observable
    final class Slot {
        fileprivate(set) var session: PiSession
        fileprivate init(_ session: PiSession) { self.session = session }
    }

    /// 键是 Pi 的会话 id；同一会话开在两个进程里时取先出现的那个（与 `sessions.first { $0.sessionID == … }` 一致）。
    private var slots: [String: Slot] = [:]

    init(_ bridge: PiBridge) {
        apply(bridge.sessions)
    }

    /// 跟着桥直到任务取消。
    func follow(_ bridge: PiBridge) async {
        for await sessions in Observations({ bridge.sessions }) { apply(sessions) }
    }

    func session(_ sessionID: String) -> PiSession? { slots[sessionID]?.session }

    private func apply(_ sessions: [PiSession]) {
        var next: [String: PiSession] = [:]
        for session in sessions where next[session.sessionID] == nil { next[session.sessionID] = session }
        for (id, session) in next {
            if let slot = slots[id] {
                if slot.session != session { slot.session = session }
            } else {
                slots[id] = Slot(session)
            }
        }
        for id in slots.keys where next[id] == nil { slots[id] = nil }
    }
}
#endif
