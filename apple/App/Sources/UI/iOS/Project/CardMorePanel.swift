#if os(iOS)
import CueStore
import SwiftUI

nonisolated struct CardMoreRequest: Identifiable, Equatable {
    let card: Card
    let opens: Bool
    let source: BubbleSource
    var id: UUID { card.id }
}

struct CardMoreSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        Color.clear
            .panel(item: $workspace.moreCard, style: .bubble(workspace.moreCard?.source ?? .unanchored, width: .fixed(BubblePlacement.maxWidth))) { CardMorePanel(card: $0.card, opens: $0.opens) }
    }
}

/// 气泡里两页，原地翻而不叠两层：叠两层读不出哪个是当前的，点外面也不知道关哪层。
private struct CardMorePanel: View {
    let card: Card
    let opens: Bool
    @State private var moving = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.closePanel) private var close
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var glyph: CGFloat = 15

    var body: some View {
        ScrollView {
            TurnStack {
                if moving {
                    projects.transition(Motion.turn(from: .trailing, reduceMotion: reduceMotion))
                } else {
                    actions.transition(Motion.turn(from: .leading, reduceMotion: reduceMotion))
                }
            }
            .padding(.bottom, Spacing.item)
        }
        .scrollBounceBehavior(.basedOnSize)
        .clipped()
        .debugCyclesTurn { flip(!moving) }
    }

    private func flip(_ to: Bool) {
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { moving = to }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(card.title).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(2)
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.group).padding(.bottom, Spacing.tight)
            ForEach(CardMenu.swipeMore(for: card, opens: opens), id: \.self) { item in
                if let run = item.run(on: card, in: workspace) {
                    Button {
                        close()
                        run()
                    } label: {
                        LinkRow(title: Text(item.title), chevron: false) { Image(item.icon) }
                    }
                    .buttonStyle(.row)
                }
            }
            if card.parentID == nil {
                let move = CardMenu.Item.move
                let here = workspace.catalog?.project(card.projectID)?.shownName
                Button { flip(true) } label: {
                    LinkRow(title: Text(move.title), value: here.map { Text(verbatim: $0) }) { Image(move.icon) }
                }
                .buttonStyle(.row)
            }
        }
    }

    private var projects: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button { flip(false) } label: {
                HStack(spacing: Spacing.glyph) {
                    Chevron(.back).foregroundStyle(palette.ink2)
                    Text(CardMenu.Item.move.title).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, Spacing.page).frame(minHeight: RowMetrics.height).contentShape(.rect)
            }
            .buttonStyle(PressStyle())
            .accessibilityLabel("返回")
            ForEach(workspace.catalog?.projects ?? []) { project in
                let here = project.id == card.projectID
                Button {
                    close()
                    let id = card.id
                    workspace.perform { try await $0.moveCard(id, to: .top(project: project.id), after: nil) }
                } label: {
                    LinkRow(title: Text(project.shownName), chevron: false) {
                        ProjectGlyph(project: project, size: glyph)
                    } trailing: {
                        if here { Image(.complete).font(Typography.meta.weight(.semibold)).foregroundStyle(palette.ink3) }
                    }
                }
                .buttonStyle(.row)
                .disabled(here)
                .accessibilityAddTraits(here ? .isSelected : [])
            }
        }
    }
}
#endif
