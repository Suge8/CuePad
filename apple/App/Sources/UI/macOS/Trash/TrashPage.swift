#if os(macOS)
import CueStore
import SwiftUI

nonisolated private struct TrashData: Sendable {
    var projects: [Project]
    /// 回收站项目各自带进来的卡片数。
    var projectCardCounts: [UUID: Int]
    var cards: [Card]
}

/// 回收站：删除的项目（连同其卡片）与单独删除的卡片；可恢复、永久删除、清空。
struct TrashPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: TrashData?
    @State private var confirmEmpty = false

    var body: some View {
        ZStack(alignment: .top) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("回收站").font(.system(size: 28, weight: .bold)).foregroundStyle(palette.ink)
                        Spacer()
                        if let data, !(data.projects.isEmpty && data.cards.isEmpty) {
                            Button("清空回收站", role: .destructive) { confirmEmpty = true }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                    }
                    if let data { content(data) }
                }
                .padding(.horizontal, 32).padding(.top, 6).padding(.bottom, 40)
            }
            TopFade()
        }
        .confirmationDialog("永久删除回收站里的全部内容？", isPresented: $confirmEmpty) {
            Button("清空", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        } message: {
            Text("此操作无法撤销。发送记录会保留当时的内容快照。")
        }
        .observing(services.store, [.projects, .cards], into: $data, onError: workspace.fail) { store in
            let projects = try store.trashedProjects()
            return TrashData(
                projects: projects,
                projectCardCounts: Dictionary(uniqueKeysWithValues: try projects.map {
                    ($0.id, try store.search(SearchQuery(projects: [$0.id], inTrash: true), limit: 0).totalCards)
                }),
                cards: try store.trashedCards())
        }
    }

    @ViewBuilder
    private func content(_ data: TrashData) -> some View {
        if data.projects.isEmpty && data.cards.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "trash").font(.system(size: 28)).foregroundStyle(palette.ink3).accessibilityHidden(true)
                Text("回收站是空的").font(.system(size: 15, weight: .semibold)).foregroundStyle(palette.ink2)
            }
            .frame(maxWidth: .infinity).padding(.top, 80)
        }
        if !data.projects.isEmpty {
            group("项目") {
                ForEach(data.projects) { project in
                    TrashRow(
                        icon: AnyView(ProjectGlyph(project: project)), title: project.name,
                        detail: "\(data.projectCardCounts[project.id] ?? 0) 条灵感与任务", deletedAt: project.deletedAt,
                        restore: { workspace.perform { try await $0.restoreProject(project.id) } },
                        purge: { workspace.perform { try await $0.purgeProject(project.id) } })
                }
            }
        }
        if !data.cards.isEmpty {
            group("灵感与任务") {
                ForEach(data.cards) { card in
                    let text = CardText(card.body)
                    TrashRow(
                        icon: AnyView(Image(systemName: "doc.text").foregroundStyle(palette.ink3).accessibilityHidden(true)),
                        title: text.title.isEmpty ? "无标题" : text.title, detail: text.preview, deletedAt: card.deletedAt,
                        restore: { workspace.perform { try await $0.restoreCard(card.id) } },
                        purge: { workspace.perform { try await $0.purgeCard(card.id) } })
                }
            }
        }
    }

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(palette.ink2)
            VStack(spacing: 0) { rows() }.paper(radius: 12)
        }
    }
}

private struct TrashRow: View {
    let icon: AnyView
    let title: String
    let detail: String
    let deletedAt: Date?
    let restore: () -> Void
    let purge: () -> Void
    @Environment(\.palette) private var palette
    @State private var confirming = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(detail).font(.system(size: 12.5)).foregroundStyle(palette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            // 操作在悬停时出现（右键菜单里也有），平时只看得到删除时间
            ZStack(alignment: .trailing) {
                if let deletedAt {
                    Text("\(DateLabel.short(deletedAt)) 删除").font(.system(size: 12)).foregroundStyle(palette.ink3)
                        .opacity(hovering ? 0 : 1)
                }
                HStack(spacing: 6) {
                    Button("恢复", action: restore).controlSize(.small)
                    Button("永久删除…") { confirming = true }.controlSize(.small).foregroundStyle(palette.failure)
                }
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 40)
        .background(hovering ? palette.fill : .clear)
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .animation(Motion.quick, value: hovering)
        .contextMenu {
            Button("恢复", action: restore)
            Button("永久删除…", role: .destructive) { confirming = true }
        }
        .confirmationDialog("永久删除「\(title)」？", isPresented: $confirming) {
            Button("永久删除", role: .destructive, action: purge)
        } message: {
            Text("此操作无法撤销。")
        }
    }
}
#endif
