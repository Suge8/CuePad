#if os(iOS)
import CueStore
import SwiftUI

/// 墙上的一张卡。点开用系统缩放过渡放大成纸页；长按是卡片操作。
struct CardTileView: View {
    let card: Card
    let lastTarget: String?
    let floated: Bool
    let isGoal: Bool
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let text = CardText(card.body)
        NavigationLink(value: Navigation.Route.card(card.id)) {
            VStack(alignment: .leading, spacing: 6) {
                if let image = text.images.first {
                    Thumbnail(hash: image, height: 96, radius: 9).padding(.bottom, 4)
                }
                Text(text.title.isEmpty ? "空白卡片" : text.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(text.title.isEmpty ? palette.ink3 : palette.ink)
                    .lineLimit(3)
                if !text.preview.isEmpty {
                    Text(VariableText.styled(text.preview, palette))
                        .font(.footnote).foregroundStyle(palette.ink2)
                        .lineLimit(text.images.isEmpty ? 5 : 2)
                }
                CardMeta(card: card, text: text, lastTarget: lastTarget, floated: floated, isGoal: isGoal, font: .caption2)
                    .padding(.top, 2)
            }
            .multilineTextAlignment(.leading)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .paper(radius: 16)
            .contentShape(.rect(cornerRadius: 16))
        }
        .buttonStyle(.plain)
        .zoomSource(card.id, in: zoom)
        .contextMenu { CardActions(card: card, isGoal: isGoal) }
    }
}

/// 卡片操作（长按菜单与编辑页"更多"共用）：置顶、设为目标、复制、转为任务、移到项目、移到回收站。
struct CardActions: View {
    let card: Card
    let isGoal: Bool
    @Environment(Workspace.self) private var workspace
    @State private var projects: [Project]?

    var body: some View {
        let id = card.id
        Button(card.isFavorite ? "取消置顶" : "置顶", systemImage: card.isFavorite ? "pin.slash" : "pin") {
            let pinned = !card.isFavorite
            workspace.perform { try await $0.updateCard(id) { $0.isFavorite = pinned } }
        }
        if let project = card.projectID {
            Button(isGoal ? "取消项目目标" : "设为项目目标", systemImage: "scope") {
                let goal = isGoal ? nil : id
                workspace.perform { try await $0.setGoal(goal, for: project) }
            }
        }
        Button("复制", systemImage: "doc.on.doc") { workspace.copy(card) }
        ShareLink(item: Outgoing.text(of: card)) { Label("分享", systemImage: "square.and.arrow.up") }
        Button("转为任务", systemImage: "checklist") {
            let title = CardText(card.body).title, project = card.projectID
            workspace.attempt {
                _ = try await workspace.createTask(title.isEmpty ? "未命名任务" : title, in: project)
                try await workspace.services.store.trashCard(id)
                workspace.say("已转为任务，原卡片在回收站")
            }
        }
        Menu("移到项目", systemImage: "folder") {
            ForEach(projects ?? []) { project in
                Button(project.name) { workspace.perform { try await $0.moveCard(id, to: project.id, after: nil) } }
                    .disabled(project.id == card.projectID)
            }
            Button("未归档") { workspace.perform { try await $0.moveCard(id, to: nil, after: nil) } }
                .disabled(card.projectID == nil)
        }
        .task { projects = try? await workspace.services.store.projects() }
        Divider()
        Button("移到回收站", systemImage: "trash", role: .destructive) {
            workspace.perform { try await $0.trashCard(id) }
        }
    }
}

extension Workspace {
    /// 复制整张卡（变量已填、编号已排），写一条发送记录。
    func copy(_ card: Card) {
        let text = Outgoing.text(of: card), id = card.id
        attempt {
            try await self.services.send(text, to: .clipboard, card: id)
            self.say("已复制")
        }
    }
}

/// "更早"：三个月内按周、更久按月（默认折叠）的紧凑列表。
struct OlderSection: View {
    let groups: [OlderGroup]
    let cards: [UUID: Card]
    let lastTarget: [UUID: String]
    @Environment(\.palette) private var palette
    @State private var expanded: Set<OlderGroup.Period> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("更早").font(.headline).foregroundStyle(palette.ink)
                Text("\(groups.reduce(0) { $0 + $1.cards.count })").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            ForEach(groups, id: \.period) { group in
                let collapsible = if case .month = group.period { true } else { false }
                let open = !collapsible || expanded.contains(group.period)
                VStack(alignment: .leading, spacing: 6) {
                    Button {
                        withAnimation(Motion.quick) {
                            if open { expanded.remove(group.period) } else { expanded.insert(group.period) }
                        }
                    } label: {
                        HStack {
                            if collapsible {
                                Image(systemName: "chevron.right").font(.caption2.weight(.bold))
                                    .rotationEffect(.degrees(open ? 90 : 0)).accessibilityHidden(true)
                            }
                            Text(OlderGroupTitle.text(group.period)).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink2)
                            Spacer()
                            Text("\(group.cards.count) 张").font(.caption).foregroundStyle(palette.ink3)
                        }
                        .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!collapsible)
                    .accessibilityValue(collapsible ? (open ? "已展开" : "已折叠") : "")
                    if open {
                        VStack(spacing: 0) {
                            ForEach(Array(group.cards.compactMap { cards[$0] }.enumerated()), id: \.element.id) { index, card in
                                if index > 0 { Divider().padding(.leading, 14) }
                                OlderRow(card: card, lastTarget: lastTarget[card.id])
                            }
                        }
                        .paper(radius: 12)
                    }
                }
            }
        }
        .padding(.top, 8)
    }
}

private struct OlderRow: View {
    let card: Card
    let lastTarget: String?
    @Environment(\.palette) private var palette
    @Environment(\.zoomNamespace) private var zoom

    var body: some View {
        let text = CardText(card.body)
        NavigationLink(value: Navigation.Route.card(card.id)) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(text.title.isEmpty ? "空白卡片" : text.title).font(.subheadline.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1)
                    if !text.preview.isEmpty {
                        Text(text.preview).font(.footnote).foregroundStyle(palette.ink3).lineLimit(1)
                    }
                }
                Spacer(minLength: 8)
                if let lastTarget { Text("→ \(lastTarget)").font(.caption2).foregroundStyle(palette.ink3).lineLimit(1) }
                Text(DateLabel.short(card.modifiedAt)).font(.caption.monospacedDigit()).foregroundStyle(palette.ink3)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .zoomSource(card.id, in: zoom)
        .contextMenu { CardActions(card: card, isGoal: false) }
    }
}

#endif
