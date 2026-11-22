import CueStore
import SwiftUI

struct CueStarters: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var agents: MacAgents?

    var body: some View {
        VStack(alignment: .trailing, spacing: Spacing.item) {
            ForEach(Self.lines(agents?.agents.map(\.kind) ?? []), id: \.self) { line in
                Button {
                    workspace.cue.draft.text = line
                    workspace.cueFocusPending = true
                } label: {
                    Text(verbatim: line)
                }
                .buttonStyle(ControlButtonStyle(kind: .glass))
            }
        }
        .observing(services.store, id: workspace.cue.hostID, into: $agents, onError: workspace.fail) { [host = workspace.cue.hostID] in
            try $0.macAgents(on: host ?? "")
        }
    }

    static func lines(_ agents: [AgentKind]) -> [String] {
        let first = agents.first?.name, second = agents.dropFirst().first?.name
        return [
            first.map { String(localized: "用 \($0) 做个番茄钟网页，截图给我") } ?? String(localized: "做个番茄钟网页，截图给我"),
            second.map { String(localized: "让 \($0) 比比三款笔记 App") } ?? String(localized: "比比三款笔记 App，写页总结"),
            String(localized: "以后推代码前先问我"),
        ]
    }
}
