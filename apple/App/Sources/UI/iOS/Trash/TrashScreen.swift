#if os(iOS)
import SwiftUI

struct TrashScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var data: TrashSummary?
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            if let data {
                if data.isEmpty {
                    EmptyState(mascot: .trash, title: "没有删掉的东西").listRowBackground(Color.clear)
                }
                if !data.projects.isEmpty {
                    Section("项目") { ForEach(data.projects) { row($0) } }
                }
                ForEach(data.runs) { run in
                    Section {
                        ForEach(run.items) { row($0) }
                    } header: {
                        ProjectRunHeader(project: data.project(of: run, in: workspace.catalog), count: run.items.count).textCase(nil)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .floatingHeader("回收站", detail: data.map { $0.isEmpty ? nil : Dotted(String(localized: "\($0.count) 项")) } ?? Dotted()) {
            Button("清空", icon: .emptyTrash, role: .destructive) { workspace.confirmsEmptyTrash = true }
                .disabled(data?.isEmpty ?? true)
        }
        .emptyTrashConfirmation(workspace)
        .observing(services.store, into: $data, onError: workspace.fail) { store in
            try TrashSummary.read(from: store)
        }
    }

    private func row(_ item: TrashItem) -> some View {
        let swipes = RowSwipes(
            leading: [RowAction("恢复", icon: .restore, tone: .primary) { workspace.restore(item) }],
            trailing: [RowAction("永久删除", icon: .trash, tone: .destructive) { workspace.purge(item) }])
        return HStack(alignment: .firstTextBaseline, spacing: Spacing.item) {
            Group {
                if let card = item.card { CardKindMark(card: card) } else { ProjectGlyph(project: item.project) }
            }
            .frame(width: CardKindMark.column)
            MetaLine(spacing: Spacing.group, gap: 0) {
                VStack(alignment: .leading, spacing: Spacing.hair) {
                    Text(item.title).foregroundStyle(palette.ink).lineLimit(1)
                    if !item.detail.isEmpty { Text(item.detail).font(Typography.meta).foregroundStyle(palette.ink2).lineLimit(1) }
                }
            } meta: {
                if let deletedAt = item.deletedAt {
                    Text(DateLabel.short(deletedAt)).font(Typography.meta).foregroundStyle(palette.ink3)
                }
            }
        }
        .listRowBackground(palette.paper)
        .listSwipes(swipes)
        .contextMenu { RowActionButtons(actions: swipes.leading + swipes.trailing) }
    }
}

#endif
