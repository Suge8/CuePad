#if os(macOS)
import CueStore
import SwiftUI

/// 回收站：删除的项目（连同其卡片）与单独删除的卡片；可恢复、永久删除、清空。
struct TrashPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: TrashSummary?
    @State private var confirmEmpty = false

    var body: some View {
        ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HStack(alignment: .lastTextBaseline) {
                        Text("回收站").font(Typography.pageTitle).foregroundStyle(palette.ink)
                        Spacer()
                        if let data, !data.isEmpty {
                            Button("清空回收站", role: .destructive) { confirmEmpty = true }
                                .buttonStyle(.glass).controlSize(.large)
                        }
                    }
                    if let data { content(data) }
                }
                .padding(.horizontal, Spacing.page).padding(.top, Spacing.pageTop).padding(.bottom, 40)
        }
        .fadesUnderBars()
        .dialog("永久删除回收站里的全部内容？", isPresented: $confirmEmpty, message: "此操作无法撤销。发送记录会保留当时的内容快照。", buttons: [
            DialogButton(title: "清空", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        ])
        .observing(services.store, [.projects, .cards], into: $data, onError: workspace.fail) { store in
            try TrashSummary.read(from: store)
        }
    }

    @ViewBuilder
    private func content(_ data: TrashSummary) -> some View {
        if data.isEmpty {
            EmptyState(mascot: .trash, title: "回收站是空的")
        }
        if !data.projects.isEmpty {
            group("项目") {
                ForEach(data.projects) { item in
                    TrashRow(item: item, restore: { workspace.restore(item) }, purge: { workspace.purge(item) }) {
                        if case .project(let project, _) = item.kind { ProjectGlyph(project: project) }
                    }
                }
            }
        }
        if !data.cards.isEmpty {
            group("灵感与任务") {
                ForEach(data.cards) { item in
                    TrashRow(item: item, restore: { workspace.restore(item) }, purge: { workspace.purge(item) }) {
                        Image(systemName: "doc.text").foregroundStyle(palette.ink3).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typography.sectionTitle).foregroundStyle(palette.ink)
            VStack(spacing: 0) { rows() }.paper(radius: 12)
        }
    }
}

private struct TrashRow<Icon: View>: View {
    let item: TrashItem
    let restore: () -> Void
    let purge: () -> Void
    @ViewBuilder let icon: Icon
    @Environment(\.palette) private var palette
    @State private var confirming = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            Text(item.title).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(item.detail).font(Typography.secondary).foregroundStyle(palette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            // 操作在悬停时出现（右键菜单里也有），平时只看得到删除时间
            ZStack(alignment: .trailing) {
                if let deletedAt = item.deletedAt {
                    Text("删于 \(DateLabel.short(deletedAt))").font(Typography.meta).foregroundStyle(palette.ink3)
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
        .dialog("永久删除「\(item.title)」？", isPresented: $confirming, message: "此操作无法撤销。", buttons: [
            DialogButton(title: "永久删除", role: .destructive) { purge() }
        ])
    }
}
#endif
