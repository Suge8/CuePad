#if os(iOS)
import CueStore
import SwiftUI

/// 回收站：删除的项目（连同其卡片）与单独删除的卡。左滑永久删除，右滑恢复。
struct TrashScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var data: TrashSummary?
    @State private var confirmEmpty = false
    @Environment(\.palette) private var palette

    var body: some View {
        List {
            if let data {
                if data.isEmpty {
                    EmptyState(mascot: .trash, title: "回收站是空的").listRowBackground(Color.clear)
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
        .floatingHeader("回收站", detail: data.map { $0.isEmpty ? "空的" : "\($0.count) 项" } ?? "") {
            // 圆钮一直在、没东西时置灰：顶栏的控件不随数据出现消失
            Button("清空", systemImage: "trash", role: .destructive) { confirmEmpty = true }
                .disabled(data?.isEmpty ?? true)
        }
        .confirmationDialog("永久删除回收站里的全部内容？", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("清空回收站", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        } message: {
            Text("此操作无法撤销。")
        }
        .observing(services.store, [.projects, .cards], into: $data, onError: workspace.fail) { store in
            try TrashSummary.read(from: store)
        }
    }

    private func row(_ item: TrashItem) -> some View {
        let swipes = RowSwipes(
            leading: [RowAction("恢复", symbol: "arrow.uturn.backward", tone: .primary) { workspace.restore(item) }],
            trailing: [RowAction("永久删除", symbol: "trash", tone: .destructive) { workspace.purge(item) }])
        // 删除时间单独靠右：摘要再长也不把它挤出去
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).foregroundStyle(palette.ink).lineLimit(1)
                if !item.detail.isEmpty { Text(item.detail).font(.footnote).foregroundStyle(palette.ink2).lineLimit(1) }
            }
            Spacer(minLength: 0)
            if let deletedAt = item.deletedAt {
                Text("删于 \(DateLabel.short(deletedAt))").font(.footnote.monospacedDigit()).foregroundStyle(palette.ink3).fixedSize()
            }
        }
        .listRowBackground(palette.paper)
        .listSwipes(swipes)
        .contextMenu { RowActionButtons(actions: swipes.leading + swipes.trailing) }
    }
}

#endif
