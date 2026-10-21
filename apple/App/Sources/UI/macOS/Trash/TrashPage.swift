#if os(macOS)
import SwiftUI

/// 回收站：删除的项目（连同其卡片）与单独删除的卡片；可恢复、永久删除、清空。
/// 顶上不写页名（侧栏底下的回收站钮已经说了在哪），顶上那一排（`pageHeader`）右边是"清空回收站"，右上"⋯"里同一下。
struct TrashPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: TrashSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if let data { content(data) }
            }
            .padding(.horizontal, Spacing.page).padding(.bottom, 40)
        }
        .pageHeader {
            HStack {
                Spacer(minLength: 0)
                if let data, !data.isEmpty {
                    Button("清空回收站…", icon: .trash, role: .destructive) { workspace.confirmsEmptyTrash = true }
                        .buttonStyle(ControlButtonStyle(kind: .glass))
                }
            }
        }
        .dialog("永久删除回收站里的全部内容？", isPresented: Bindable(workspace).confirmsEmptyTrash, message: "此操作无法撤销。发送记录会保留当时的内容快照。", buttons: [
            DialogButton(title: "清空", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        ])
        .observing(services.store, into: $data, onError: workspace.fail) { store in
            try TrashSummary.read(from: store)
        }
    }

    @ViewBuilder
    private func content(_ data: TrashSummary) -> some View {
        if data.isEmpty {
            EmptyState(mascot: .trash, title: "没有删掉的东西")
        }
        if !data.projects.isEmpty {
            group("项目") {
                ForEach(data.projects) { item in
                    TrashRow(item: item, restore: { workspace.restore(item) }, purge: { workspace.purge(item) }) {
                        ProjectGlyph(project: item.project)
                    }
                }
            }
        }
        if !data.cards.isEmpty {
            group("灵感与任务") {
                ForEach(data.cards) { item in
                    TrashRow(item: item, restore: { workspace.restore(item) }, purge: { workspace.purge(item) }) {
                        Image(.document).foregroundStyle(palette.ink3).accessibilityHidden(true)
                    }
                }
            }
        }
    }

    private func group(_ title: String, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(Typography.sectionTitle).foregroundStyle(palette.ink)
            VStack(spacing: 0) { rows() }.rowPaper(radius: 12)
        }
    }
}

/// 回收站的一行：指针停着时铺行的淡底（`RowStyle`），行尾浮出恢复与永久删除、盖住删除时间（`hoverReveal`；右键菜单里也有）。
private struct TrashRow<Icon: View>: View {
    let item: TrashItem
    let restore: () -> Void
    let purge: () -> Void
    @ViewBuilder let icon: Icon
    @Environment(\.palette) private var palette
    @State private var confirming = false

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 20)
            Text(item.title).font(Typography.body.weight(.medium)).foregroundStyle(palette.ink).lineLimit(1).layoutPriority(1)
            Text(item.detail).font(Typography.secondary).foregroundStyle(palette.ink3).lineLimit(1)
            Spacer(minLength: 12)
            if let deletedAt = item.deletedAt {
                Text("删于 \(DateLabel.short(deletedAt))").font(Typography.meta).foregroundStyle(palette.ink3)
            }
        }
        .padding(.horizontal, 12).frame(minHeight: 40)
        .hoverReveal {
            HStack(spacing: 6) {
                Button("恢复", action: restore).controlSize(.small)
                Button("永久删除…") { confirming = true }.controlSize(.small).foregroundStyle(palette.failure)
            }
            .padding(.horizontal, 12)
        }
        .row()
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
