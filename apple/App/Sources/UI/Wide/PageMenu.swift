import SwiftUI

struct ProjectScopeSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let current = workspace.catalog?.project(workspace.scopedProject)
        Menu { ProjectScopePicker().pickerStyle(.inline).labelStyle(.titleAndIcon) } label: {
            ProjectScopeLabel().menuLabel(current.map { "项目范围：\($0.shownName)" } ?? "项目范围：全部项目")
        }
        .menuStyle(.button).menuIndicator(.hidden)
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .fixedSize()
        .help("项目范围")
        .sensoryFeedback(.selection, trigger: workspace.scopedProject)
    }
}

struct EmptyTrashButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("清空回收站…", icon: .emptyTrash) { workspace.confirmsEmptyTrash = true }
            .help("清空回收站")
    }
}

extension View {
    func emptyTrashConfirmation(_ workspace: Workspace) -> some View {
        dialog(
            "永久删除回收站里的全部内容？", isPresented: Bindable(workspace).confirmsEmptyTrash,
            message: "此操作无法撤销。发送记录会保留当时的内容快照。", buttons: [
            DialogButton(title: "清空回收站", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        ])
    }
}
