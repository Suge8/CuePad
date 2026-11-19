#if os(macOS)
import SwiftUI

struct TrashPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: TrashSummary?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.part) {
                if let data { content(data) }
            }
            .storedList()
        }
        .safeAreaPadding(.top, Bars.contentGap)
        .emptyTrashConfirmation(workspace)
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

    private func group(_ title: LocalizedStringResource, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            SectionHeader(title)
            VStack(spacing: 0) { rows() }
        }
    }
}

private struct TrashRow<Mark: View>: View {
    let item: TrashItem
    let restore: () -> Void
    let purge: () -> Void
    @ViewBuilder let mark: Mark
    @State private var confirming = false

    var body: some View {
        StoredRow(title: item.title, detail: item.detail, stamp: item.deletedAt) {
            mark
        } actions: {
            Button("恢复", icon: .restore, action: restore).help("恢复")
            Button("永久删除…", icon: .trash, role: .destructive) { confirming = true }.help("永久删除")
        }
        .contextMenu {
            Button("恢复", icon: .restore, action: restore).menuIcons()
            Divider()
            Button("永久删除…", icon: .trash, role: .destructive) { confirming = true }.menuIcons()
        }
        .dialog("永久删除「\(item.title)」？", isPresented: $confirming, message: "此操作无法撤销。", buttons: [
            DialogButton(title: "永久删除", role: .destructive) { purge() }
        ])
    }
}

#endif
