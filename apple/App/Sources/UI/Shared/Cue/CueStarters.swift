import CueStore
import SwiftUI

/// 还没对 Cue 说过话时，空态里给的几句能直接说的话：点一句放进输入框（可改了再发），点名的 Agent 是 Cue 运行的那台 Mac 上能用的
/// （`MacAgents`，第一家就是 Cue 开工时的缺省）。三句各示范一件它会做的事：派活并拿截图核对、交给另一家去调研、记下你的规矩。
struct CueStarters: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var agents: MacAgents?

    var body: some View {
        VStack(spacing: 8) {
            ForEach(Self.lines(agents?.agents.map(\.kind) ?? []), id: \.self) { line in
                EmptyStateButton(title: line, icon: nil, kind: .small) {
                    workspace.cue.draft.text = line
                    workspace.cueFocusPending = true
                }
            }
        }
        .observing(services.store, id: workspace.cue.hostID, into: $agents, onError: workspace.fail) { [host = workspace.cue.hostID] in
            try $0.macAgents(on: host ?? "")
        }
    }

    static func lines(_ agents: [AgentKind]) -> [String] {
        let first = agents.first.map { "用 \($0.name) " } ?? ""
        let second = agents.dropFirst().first.map { "让 \($0.name) " } ?? ""
        return ["\(first)做一个番茄钟网页，做好截图给我看", "\(second)调研三款笔记 App 的优缺点，写一页总结", "以后推送代码前先问我"]
    }
}
