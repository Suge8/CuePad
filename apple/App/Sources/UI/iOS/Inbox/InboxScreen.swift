#if os(iOS)
import CueStore
import SwiftUI

/// 未分类：还没归进项目的灵感，一条一行，最近的在前。点开看全文；右滑交给 Agent，左滑设为任务或移到项目（归完就离开这里）；
/// 交给过 Agent 的行尾是那个会话的状态点。
struct InboxScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var cards: [Card]?
    @State private var moving: Card?
    @State private var agents: AgentLinks?

    var body: some View {
        List {
            if let cards {
                if cards.isEmpty {
                    EmptyIdeas { navigation.startCapture(project: .some(nil)) }
                        .listRowBackground(Color.clear)
                } else {
                    Section {
                        ForEach(cards) { card in row(card) }
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .animation(Motion.quick, value: cards?.map(\.id))
        .floatingHeader(CaptureCopy.inbox, detail: cards.map { $0.isEmpty ? "" : "\($0.count) 条" } ?? "")
        .sheet(item: $moving) { MoveToProjectSheet(card: $0) }
        .environment(\.cardAgents, agents ?? AgentLinks(items: [:], launching: []))
        .observing(services.store, [.cards], into: $cards, onError: workspace.fail) { store in
            try store.cards(in: nil).sorted { $0.modifiedAt > $1.modifiedAt }
        }
        .observing(services.store, AgentLinks.tables, into: $agents, onError: workspace.fail) { try AgentLinks.read(from: $0) }
    }

    private func row(_ card: Card) -> some View {
        let text = CardText(card.body)
        return Button { navigation.open(card: card.id) } label: {
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(text.label).font(.body.weight(.medium))
                        .foregroundStyle(palette.ink).lineLimit(2)
                    Spacer(minLength: 4)
                    AgentDot(card: card.id).padding(.vertical, -8)
                }
                if !text.preview.isEmpty {
                    Text(text.preview).font(.subheadline).foregroundStyle(palette.ink2).lineLimit(2)
                }
                Text(DateLabel.short(card.modifiedAt)).font(.caption).foregroundStyle(palette.ink3)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowBackground(palette.paper)
        .swipeActions(edge: .leading) {
            Button("交给 Agent", systemImage: "paperplane.fill") { navigation.handToAgent(card) }.tint(palette.signature)
        }
        .swipeActions(edge: .trailing) {
            Button("设为任务", systemImage: "checklist") { workspace.toggleTodo(card.id, true) }.tint(palette.ink)
            Button("移到项目", systemImage: "folder") { moving = card }.tint(palette.ink2)
        }
        .contextMenu { CardActions(card: card) }
    }
}

/// 选一个项目，把这张卡移过去（顺序同所有项目选择器：`ProjectCatalog.projects`）。
private struct MoveToProjectSheet: View {
    let card: Card
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            List {
                ForEach(workspace.catalog?.projects ?? []) { project in
                    Button { move(to: project) } label: {
                        HStack(spacing: 12) {
                            ProjectGlyph(project: project, size: 15)
                            Text(project.name).foregroundStyle(palette.ink)
                            Spacer(minLength: 8)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(palette.paper)
                }
            }
            .deskBackground()
            .navigationTitle("移到项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("关闭", systemImage: "xmark", role: .cancel) { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func move(to project: Project) {
        let id = card.id
        dismiss()
        workspace.perform { try await $0.moveCard(id, to: .top(project: project.id), after: nil) }
        workspace.say("已移到 \(project.name)", link: .project(project.id))
    }
}
#endif
