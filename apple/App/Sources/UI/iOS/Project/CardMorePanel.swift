#if os(iOS)
import CueStore
import SwiftUI

/// 任务行左滑"⋯ 更多"长出的气泡：从按下的那一下长出来（同任务气泡，`PanelStyle.bubble`）。
nonisolated struct CardMoreRequest: Identifiable, Equatable {
    let card: Card
    /// 点这一行进的是会话（`Workspace.enter`）：气泡里先是"打开任务"。
    let opens: Bool
    let source: BubbleSource
    var id: UUID { card.id }
}

/// 挂在窗口上的那一格（同 `TaskBubbleSlot`）：只有它读 `Workspace.moreCard`。
struct CardMoreSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        @Bindable var workspace = workspace
        Color.clear
            .panel(item: $workspace.moreCard, style: .bubble(workspace.moreCard?.source ?? .unanchored, width: .fixed(BubblePlacement.maxWidth))) { CardMorePanel(card: $0.card, opens: $0.opens) }
    }
}

/// 气泡里两页，原地翻（同任务气泡翻到子任务：叠两层气泡读不出哪个是当前的，点外面也不知道关哪层）：
/// - 第一页：头一行是这条任务的标题；下面是 `CardMenu.swipeMore` 那几项（做法同菜单，`CardMenu.Item.run`），末行"移到项目 当前项目 ›"。
///   删除在轻扫的最外侧，这里不放；子任务跟着上级走，没有末行。
/// - 第二页：左上"‹"返回第一页，标题"移到项目"；项目一行一个点选，当前所在的那个打勾、点不了。项目多时在里面滚。
/// 往里翻从右边进、返回从左边进（同推入与返回）。
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
            Group {
                if moving { projects.transition(page(from: .trailing)) } else { actions.transition(page(from: .leading)) }
            }
            .padding(.bottom, Spacing.item)
        }
        .scrollBounceBehavior(.basedOnSize)
        .clipped()
    }

    private func page(from edge: Edge) -> AnyTransition {
        reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity)
    }

    private func flip(_ to: Bool) {
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { moving = to }
    }

    private var actions: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(card.title).font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(2)
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.group).padding(.bottom, 6)
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
