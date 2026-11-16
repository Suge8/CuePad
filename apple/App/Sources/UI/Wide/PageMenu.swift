import SwiftUI

/// 宽屏栏头里这一页自己的那颗钮（Mac 与 iPad 同一个，`WideColumnHead`）；栏里的页不在自己那一排另给（`HeaderHost.column` 不画页的右端）。
/// 不设"⋯"：一页的操作要么直接是一颗钮，要么挨着它管的那块内容。项目页的在标题旁（`WideProjectHeading`），别的页没有。

/// 进展页的项目范围（筛选的图形，选了项目时角上是那个项目），排在列头那一排的开头：先选范围再看四列，
/// 右端留给滑到 Cue 浮板下面的列，压在最后一列的列头上会盖住列名。那一页别的操作各在原处——归档做完的在已完成那一列的列头，接入 Agent 在设置。
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

/// 回收站页的清空。不按页面数据置灰：栏头拿不到页面读的库，抄一份过来就是第二个事实源；没有可清空的时候点了什么也不发生。
struct EmptyTrashSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("清空回收站…", icon: .trash, role: .destructive) { workspace.confirmsEmptyTrash = true }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .padding(.leading, Spacing.item)
            .help("清空回收站")
    }
}

extension View {
    /// 清空回收站的确认只此一份：宽屏栏头与手机页头的圆钮都只是把它打开（`Workspace.confirmsEmptyTrash`），挂在回收站页上。
    func emptyTrashConfirmation(_ workspace: Workspace) -> some View {
        dialog(
            "永久删除回收站里的全部内容？", isPresented: Bindable(workspace).confirmsEmptyTrash,
            message: "此操作无法撤销。发送记录会保留当时的内容快照。", buttons: [
            DialogButton(title: "清空回收站", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        ])
    }
}
