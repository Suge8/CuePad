#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// 卡片墙：列数随宽度（理想列宽 260），分列由 `WallColumns` 决定并保持稳定——存新卡时新卡进最矮一列的顶部，
/// 同列的卡往下挪（有动画），别列的卡不动；只有列数变化时重新分配，且不做动画。
struct WallGrid<Tile: View>: View {
    let ids: [UUID]
    let cards: [UUID: Card]
    @ViewBuilder let tile: (Card) -> Tile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var width: CGFloat = 0
    @State private var layout: WallColumns?

    private static var spacing: CGFloat { 16 }
    private static var idealColumnWidth: CGFloat { 260 }

    var body: some View {
        HStack(alignment: .top, spacing: Self.spacing) {
            ForEach(Array((layout?.columns ?? []).enumerated()), id: \.offset) { _, column in
                VStack(spacing: Self.spacing) {
                    ForEach(column, id: \.self) { id in
                        if let card = cards[id] {
                            tile(card).transition(.opacity.combined(with: .scale(scale: 0.98)))
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .top)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { newWidth in
            width = newWidth
            relayout(animated: false)
        }
        .onChange(of: ids) { relayout(animated: true) }
    }

    private func relayout(animated: Bool) {
        guard width > 0 else { return }
        let count = WallColumns.count(for: width, idealColumnWidth: Self.idealColumnWidth, spacing: Self.spacing)
        let columnWidth = (width - Self.spacing * CGFloat(count - 1)) / CGFloat(count)
        let cards = cards
        let height = { (id: UUID) in cards[id].map { WallColumns.estimatedHeight(of: CardText($0.body), columnWidth: columnWidth) } ?? 0 }
        var next = layout ?? WallColumns(order: ids, count: count, height: height)
        next.update(order: ids, count: count, height: height)
        guard next != layout else { return }
        // 列数变了（窗口跨档）直接落位；同列挪动与新卡入场走短弹簧
        if animated, layout?.columns.count == count {
            withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { layout = next }
        } else {
            layout = next
        }
    }
}

/// 墙上的一张卡：标题、首图、摘要、元信息（时间、块数、发送目标、浮回与置顶标记）。
struct CardTile: View {
    let card: Card
    let lastTarget: String?
    let floated: Bool
    let isGoal: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let text = CardText(card.body)
        let isOpen = workspace.openCard == card.id
        Button(action: open) {
        VStack(alignment: .leading, spacing: 8) {
            if let image = text.images.first {
                Thumbnail(hash: image, height: 118).padding(-8).padding(.bottom, 6)
            }
            Text(text.title.isEmpty ? "空白卡片" : text.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                .lineLimit(2)
            if !text.preview.isEmpty {
                Text(VariableText.styled(text.preview, palette))
                    .font(.system(size: 13)).lineSpacing(3).foregroundStyle(palette.ink2)
                    .lineLimit(text.images.isEmpty ? 4 : 2)
            }
            CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated, isGoal: isGoal)
                .padding(.top, 2)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .paper(radius: 16, lifted: hovering)
        .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(CardPressStyle())
        .offset(y: hovering && !reduceMotion ? -1 : 0)
        .opacity(isOpen ? 0 : 1)
        .cardFrameSource(card.id, in: workspace)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu { CardMenu(card: card, isGoal: isGoal) }
        .accessibilityElement(children: .combine)
    }

    private func open() {
        workspace.openCard = card.id
    }
}

/// 卡片右键菜单。
struct CardMenu: View {
    let card: Card
    let isGoal: Bool
    @Environment(Workspace.self) private var workspace
    @State private var projects: [Project]?

    var body: some View {
        let id = card.id
        Button("打开") { workspace.openCard = id }
        Button(card.isFavorite ? "取消置顶" : "置顶") {
            let pinned = !card.isFavorite
            workspace.perform { try await $0.updateCard(id) { $0.isFavorite = pinned } }
        }
        if let project = card.projectID {
            Button(isGoal ? "取消项目目标" : "设为项目目标") {
                let goal = isGoal ? nil : id
                workspace.perform { try await $0.setGoal(goal, for: project) }
            }
        }
        Divider()
        Button("复制") { Task { await workspace.send(Outgoing.text(of: card), via: .clipboard, card: id) } }
        let choice = workspace.effectiveChoice(for: card.projectID)
        Button("发给 \(workspace.label(for: choice))") {
            Task { await workspace.send(Outgoing.text(of: card), via: choice, card: id) }
        }
        Button("转为任务") {
            let title = CardText(card.body).title, project = card.projectID
            workspace.attempt {
                _ = try await workspace.createTask(title.isEmpty ? "未命名任务" : title, in: project)
                try await workspace.services.store.trashCard(id)
            }
            workspace.say("已转为任务，原卡片在回收站")
        }
        Menu("移到项目") {
            ForEach(projects ?? []) { project in
                Button(project.name) { workspace.perform { try await $0.moveCard(id, to: project.id, after: nil) } }
                    .disabled(project.id == card.projectID)
            }
            Button("未归档") { workspace.perform { try await $0.moveCard(id, to: nil, after: nil) } }
                .disabled(card.projectID == nil)
        }
        .task { projects = try? await workspace.services.store.projects() }
        Divider()
        Button("移到回收站", role: .destructive) {
            if workspace.openCard == id { workspace.openCard = nil }
            workspace.perform { try await $0.trashCard(id) }
        }
    }
}

#endif
