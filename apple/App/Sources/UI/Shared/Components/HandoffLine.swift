import CueStore
import SwiftUI

extension Workspace {
    func handoff(of session: SessionState, shown: SessionShown? = nil) -> CueHandoff? {
        let id = session.sessionID
        guard let handoff = services.sessionFeed.handoffs[id],
              (shown ?? self.shown(session, delivery: services.sessionFeed.deliveries[id])).status == .resting else { return nil }
        return handoff
    }
}

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
    let session: SessionState
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
