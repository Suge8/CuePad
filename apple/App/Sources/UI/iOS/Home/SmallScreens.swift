#if os(iOS)
import CueStore
import SwiftUI

/// 新建或编辑项目：名称、图标、颜色。
struct ProjectFormSheet: View {
    let project: Project?
    @Environment(Workspace.self) private var workspace
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var icon = "folder"
    @State private var color = ProjectStylePicker.colors[0].hex

    var body: some View {
        NavigationStack {
            Form {
                TextField("名称", text: $name).submitLabel(.done).onSubmit(save)
                Section("图标与颜色") { ProjectStylePicker(icon: $icon, color: $color, cell: 44) }
            }
            .navigationTitle(project == nil ? "新建项目" : "编辑项目")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(project == nil ? "创建" : "保存", action: save)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .onAppear {
            guard let project else { return }
            name = project.name
            icon = ProjectGlyph.symbol(project.icon)
            color = project.color
        }
    }

    private func save() {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let project = project, icon = icon, color = color
        workspace.attempt { _ = try await workspace.saveProject(project, name: name, icon: icon, color: color) }
        dismiss()
    }
}

nonisolated private struct TrashData: Sendable {
    var projects: [(project: Project, cards: Int)]
    var cards: [Card]
}

/// 回收站：删除的项目（连同其卡片）与单独删除的卡。左滑永久删除，右滑恢复。
struct TrashScreen: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @State private var data: TrashData?
    @State private var confirmEmpty = false

    var body: some View {
        List {
            if let data {
                if data.projects.isEmpty && data.cards.isEmpty {
                    ContentUnavailableView("回收站是空的", systemImage: "trash")
                }
                if !data.projects.isEmpty {
                    Section("项目") {
                        ForEach(data.projects, id: \.project.id) { item in
                            row(title: item.project.name, detail: "\(item.cards) 张卡片", deletedAt: item.project.deletedAt,
                                restore: { try await $0.restoreProject(item.project.id) },
                                purge: { try await $0.purgeProject(item.project.id) })
                        }
                    }
                }
                if !data.cards.isEmpty {
                    Section("卡片") {
                        ForEach(data.cards) { card in
                            let text = CardText(card.body)
                            row(title: text.title.isEmpty ? "空白卡片" : text.title, detail: text.preview, deletedAt: card.deletedAt,
                                restore: { try await $0.restoreCard(card.id) },
                                purge: { try await $0.purgeCard(card.id) })
                        }
                    }
                }
            }
        }
        .navigationTitle("回收站")
        .toolbar {
            if let data, !(data.projects.isEmpty && data.cards.isEmpty) {
                Button("清空", role: .destructive) { confirmEmpty = true }
            }
        }
        .confirmationDialog("永久删除回收站里的全部内容？", isPresented: $confirmEmpty, titleVisibility: .visible) {
            Button("清空回收站", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        } message: {
            Text("此操作无法撤销。")
        }
        .observing(services.store, [.projects, .cards], into: $data, onError: workspace.fail) { store in
            TrashData(
                projects: try store.trashedProjects().map {
                    ($0, try store.search(SearchQuery(projects: [$0.id], inTrash: true), limit: 0).totalCards)
                },
                cards: try store.trashedCards())
        }
    }

    private func row(
        title: String, detail: String, deletedAt: Date?,
        restore: @escaping @Sendable (CueStore) async throws -> Void, purge: @escaping @Sendable (CueStore) async throws -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).lineLimit(1)
            Text([detail, deletedAt.map { "\(DateLabel.short($0)) 删除" }].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
        }
        .swipeActions(edge: .leading) {
            Button("恢复", systemImage: "arrow.uturn.backward") { workspace.perform(restore) }.tint(.blue)
        }
        .swipeActions(edge: .trailing) {
            Button("永久删除", systemImage: "trash", role: .destructive) { workspace.perform(purge) }
        }
        .contextMenu {
            Button("恢复", systemImage: "arrow.uturn.backward") { workspace.perform(restore) }
            Button("永久删除", systemImage: "trash", role: .destructive) { workspace.perform(purge) }
        }
    }
}

/// 设置：主题。
struct SettingsScreen: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var settings = services.settings
        Form {
            Section("外观") {
                Picker("主题", selection: $settings.theme) {
                    Text("跟随系统").tag(AppSettings.Theme.system)
                    Text("浅色").tag(AppSettings.Theme.light)
                    Text("深色").tag(AppSettings.Theme.dark)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
        }
        .navigationTitle("设置")
    }
}
#endif
