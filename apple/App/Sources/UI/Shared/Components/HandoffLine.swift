import CueStore
import SwiftUI

extension Workspace {
    /// 这个会话歇着、在等 Cue 交出去的那一处做完（`CueHandoff`，此刻有事的会话一起读的那份 `LiveSessions.handoffs`）：各处只经这里问——
    /// 会话行、看板卡、任务气泡写那一句（`HandoffLine`），菜单里多一项去那一处（`HandoffButton`）。别的状态没有：状态由状态标与状态词表达。
    /// `shown`：调用处已推好的样子；不给时这里推。
    func handoff(of session: PiSessionState, shown: PiShown? = nil) -> CueHandoff? {
        let id = session.sessionID
        guard let handoff = services.liveSessions.handoffs[id],
              (shown ?? self.shown(session, delivery: services.liveSessions.deliveries[id])).status == .resting else { return nil }
        return handoff
    }
}

/// 歇着的会话在等哪一处做完（会话卡片第二行、窄处的状态一行、看板卡下沿、任务气泡）：行首是 Cue 交出去那个动作的图标（与 Cue 页经过里同一个，`CueTrace.icon`），
/// 写得下就点名（"等 cuepad 做完"），写不下换成不点名的那句（"等另一个会话做完"，默认字号下最窄的看板卡也放得下）；字体与颜色随调用处。
struct HandoffLine: View {
    let handoff: CueHandoff

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(handoff.waiting).fixedSize()
            line(handoff.waitingUnnamed)
        }
    }

    private func line(_ text: String) -> some View {
        HStack(spacing: 4) {
            Image(CueTrace.icon(handoff.kind)).accessibilityHidden(true)
            Text(text).lineLimit(1)
        }
    }
}

/// 菜单与读屏动作里去那一处的一项（会话行、看板卡的长按与右键菜单）："打开 cuepad"，点了进那个会话或开那件任务；不在等谁时没有。
struct HandoffButton: View {
    let session: PiSessionState
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if let handoff = workspace.handoff(of: session) {
            Button("打开 \(handoff.name)", icon: CueTrace.icon(handoff.kind)) { workspace.open(handoff.target) }
        }
    }
}

extension CueHandoff {
    /// 点名的那句（读屏念它）
    var waiting: String { String(localized: "等 \(name) 做完") }
    var waitingUnnamed: String { task ? String(localized: "等另一件任务做完") : String(localized: "等另一个会话做完") }
    var target: CueWakeHeader.Target { task ? .task(place) : .session(place, sessionID: nil) }
}
