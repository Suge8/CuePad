import CueStore
import SwiftUI

/// 点名的 Agent 是 Cue 运行的那台 Mac 上能用的（`MacAgents`，第一家就是 Cue 开工时的缺省）。
struct CueStarters: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var agents: MacAgents?

    var body: some View {
        VStack(spacing: Spacing.item) {
            ForEach(Self.lines(agents?.agents.map(\.kind) ?? []), id: \.self) { line in
                Button {
                    workspace.cue.draft.text = line
                    workspace.cueFocusPending = true
                } label: {
                    Text(verbatim: line)
                }
                .buttonStyle(ControlButtonStyle(size: .compact))
            }
        }
        .observing(services.store, id: workspace.cue.hostID, into: $agents, onError: workspace.fail) { [host = workspace.cue.hostID] in
            try $0.macAgents(on: host ?? "")
        }
    }

    static func lines(_ agents: [AgentKind]) -> [String] {
        let first = agents.first?.name, second = agents.dropFirst().first?.name
        return [
            first.map { String(localized: "用 \($0) 做一个番茄钟网页，做好截图给我看") } ?? String(localized: "做一个番茄钟网页，做好截图给我看"),
            second.map { String(localized: "让 \($0) 调研三款笔记 App 的优缺点，写一页总结") } ?? String(localized: "调研三款笔记 App 的优缺点，写一页总结"),
            String(localized: "以后推送代码前先问我"),
        ]
    }
}
