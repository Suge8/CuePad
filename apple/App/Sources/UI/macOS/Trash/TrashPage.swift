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
            group { SectionHeader("项目") } rows: {
                ForEach(data.projects) { item in
                    TrashRow(item: item, restore: { workspace.restore(item) }, purge: { workspace.purge(item) }) {
                        ProjectGlyph(project: item.project)
                    }
                }
            }
        }
        // 单独删掉的灵感与任务按原来的项目分段，同归档（`ArchiveList`）
        ForEach(data.runs) { run in
            group { ProjectRunHeader(project: data.project(of: run, in: workspace.catalog), count: run.items.count) } rows: {
                ForEach(run.items) { item in
                    TrashRow(item: item, restore: { workspace.restore(item) }, purge: { workspace.purge(item) }) {
                        if let card = item.card { CardKindMark(card: card) }
                    }
                }
            }
        }
    }

    private func group(@ViewBuilder header: () -> some View, @ViewBuilder rows: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: Spacing.tight) {
            header()
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
