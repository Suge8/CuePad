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
                if !data.cards.isEmpty {
                    Section("灵感与任务") { ForEach(data.cards) { row($0) } }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .floatingHeader("回收站", detail: data.map { $0.isEmpty ? nil : Dotted(String(localized: "\($0.count) 项")) } ?? Dotted()) {
            // 圆钮一直在、没东西时置灰：顶栏的控件不随数据出现消失
            Button("清空", icon: .trash, role: .destructive) { workspace.confirmsEmptyTrash = true }
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
        // 删除时间单独靠右：摘要再长也不把它挤出去
        return MetaLine(spacing: Spacing.group, gap: 0) {
            VStack(alignment: .leading, spacing: Spacing.hair) {
                Text(item.title).foregroundStyle(palette.ink).lineLimit(1)
                if !item.detail.isEmpty { Text(item.detail).font(Typography.meta).foregroundStyle(palette.ink2).lineLimit(1) }
            }
        } meta: {
            if let deletedAt = item.deletedAt {
                Text("删于 \(DateLabel.short(deletedAt))").font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
            }
        }
        .listRowBackground(palette.paper)
        .listSwipes(swipes)
        .contextMenu { RowActionButtons(actions: swipes.leading + swipes.trailing) }
    }
}

#endif
