#if os(macOS)
import CueStore
import CueText
import SwiftUI

/// 瀑布墙：列数随宽度变化，每张卡按实测高度放进当前最短的列，墙底边尽量齐。
struct MasonryLayout: Layout {
    var minColumnWidth: CGFloat = 220
    var maxColumns = 4
    var spacing: CGFloat = 16

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 900
        let frames = place(subviews, width: width)
        return CGSize(width: width, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, place(subviews, width: bounds.width)) {
            subview.place(
                at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                proposal: ProposedViewSize(width: frame.width, height: frame.height))
        }
    }

    private func place(_ subviews: Subviews, width: CGFloat) -> [CGRect] {
        let columns = max(1, min(maxColumns, Int((width + spacing) / (minColumnWidth + spacing))))
        let columnWidth = (width - spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights = Array(repeating: CGFloat(0), count: columns)
        return subviews.map { subview in
            let column = heights.indices.min { heights[$0] < heights[$1] } ?? 0
            let height = subview.sizeThatFits(ProposedViewSize(width: columnWidth, height: nil)).height
            let frame = CGRect(x: CGFloat(column) * (columnWidth + spacing), y: heights[column], width: columnWidth, height: height)
            heights[column] += height + spacing
            return frame
        }
    }
}

/// 墙上的一张卡：标题、首图、摘要、元信息（时间、块数、发送目标、浮回与置顶标记）。
struct CardTile: View {
    let card: Card
    let lastTarget: String?
    let floated: Bool
    let isGoal: Bool
    let paperSpace: Namespace.ID
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false

    var body: some View {
        let text = CardText(card.body)
        let isOpen = workspace.openCard == card.id
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
        .offset(y: hovering && !reduceMotion ? -1 : 0)
        .opacity(isOpen ? 0 : 1)
        .matchedGeometryEffect(id: card.id, in: paperSpace, isSource: !isOpen)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .onTapGesture { open() }
        .contextMenu { CardMenu(card: card, isGoal: isGoal) }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { open() }
    }

    private func open() {
        withAnimation(Motion.spatial(Motion.paper, reduceMotion: reduceMotion)) { workspace.openCard = card.id }
    }
}

private struct CardMeta: View {
    let card: Card
    let text: CardText
    let lastTarget: String?
    let floated: Bool
    let isGoal: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 8) {
            Text(DateLabel.short(card.modifiedAt))
            if text.blockCount > 1 { Text("\(text.blockCount) 块") }
            if let lastTarget {
                Label(lastTarget, systemImage: "checkmark").labelStyle(.titleAndIcon).lineLimit(1)
                    .accessibilityLabel("已发给 \(lastTarget)")
            } else {
                Text("未发送")
            }
            Spacer(minLength: 0)
            if isGoal { Image(systemName: "scope").help("项目目标").accessibilityLabel("项目目标") }
            if floated { Image(systemName: "arrow.up").help("从更早回到墙上").accessibilityLabel("从更早回到墙上") }
            if card.isFavorite { Image(systemName: "pin.fill").help("置顶").accessibilityLabel("置顶") }
        }
        .font(.system(size: 11))
        .foregroundStyle(palette.ink3)
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

/// 附件缩略图：按内容哈希从附件目录降采样读取，读不到时显示占位底色。
struct Thumbnail: View {
    let hash: String
    var height: CGFloat
    var radius: CGFloat = 10
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.displayScale) private var scale
    @State private var image: CGImage?

    var body: some View {
        Rectangle()
            .fill(palette.fill)
            .overlay {
                if let image {
                    Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill)
                }
            }
            .frame(height: height)
            .frame(maxWidth: .infinity)
            .clipShape(.rect(cornerRadius: radius))
            .overlay(RoundedRectangle(cornerRadius: radius).strokeBorder((palette.dark ? Color.white : .black).opacity(0.1)))
            .task(id: hash) {
                let files = services.store.files, pixels = Int(height * 3 * scale)
                image = await Task.detached(priority: .utility) { try? files.thumbnail(hash: hash, maxPixel: pixels) }.value
            }
    }
}

/// 预览文字里的 `{{变量}}` 染成墨色标注。
enum VariableText {
    static func styled(_ text: String, _ palette: Palette) -> AttributedString {
        var result = AttributedString(text)
        let utf16 = text.utf16
        for range in CueVariables.ranges(in: text, within: NSRange(location: 0, length: utf16.count)) {
            guard let swiftRange = Range(range, in: text), let attributed = Range(swiftRange, in: result) else { continue }
            result[attributed].foregroundColor = palette.variable
            result[attributed].backgroundColor = palette.variableBackground
        }
        return result
    }
}
#endif
