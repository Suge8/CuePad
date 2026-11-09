import CueStore
import SwiftUI

extension Workspace {
    /// 各处只经这里问。别的状态没有：状态由状态标与状态词表达。`shown`：调用处已推好的样子；不给时这里推。
    func handoff(of session: PiSessionState, shown: PiShown? = nil) -> CueHandoff? {
        let id = session.sessionID
        guard let handoff = services.liveSessions.handoffs[id],
              (shown ?? self.shown(session, delivery: services.liveSessions.deliveries[id])).status == .resting else { return nil }
        return handoff
    }
}

/// 写不下点名的就换成不点名的那句，默认字号下最窄的看板卡也放得下。
struct HandoffLine: View {
    let handoff: CueHandoff

    var body: some View {
        ViewThatFits(in: .horizontal) {
            line(handoff.waiting).fixedSize()
            line(handoff.waitingUnnamed)
        }
    }

    private func line(_ text: String) -> some View {
        HStack(spacing: Spacing.tight) {
            Image(CueTrace.icon(handoff.kind)).readerHidden(true)
            Text(text).lineLimit(1)
        }
    }
}

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
    var waiting: String { String(localized: "等 \(name) 做完") }
    var waitingUnnamed: String { task ? String(localized: "等另一件任务做完") : String(localized: "等另一个会话做完") }
    var target: CueWakeHeader.Target { task ? .task(place) : .session(place, sessionID: nil) }
}
