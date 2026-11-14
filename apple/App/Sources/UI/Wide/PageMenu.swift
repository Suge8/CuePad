import SwiftUI

/// 宽屏这一页的操作只在栏头这颗钮（Mac 与 iPad 同一个，`WideColumnHead`）：栏里的页不在自己那一排另给（`HeaderHost.column` 不画页的右端）。
/// 菜单项不按页面数据置灰：菜单拿不到页面读的库，抄一份过来就是第二个事实源；没有可清空的时候点了什么也不发生。
/// 进展页它是项目范围（筛选的图形，选了项目时角上是那个项目），排在列头那一排的开头（`leads`）：先选范围再看四列，
/// 右端留给滑到 Cue 浮板下面的列，压在最后一列的列头上会盖住列名。那一页别的操作各在原处——归档做完的在已完成那一列的列头，接入 Agent 在设置。
struct PageMenuSlot: View {
    var leads = false
    @Environment(Workspace.self) private var workspace

    private enum Content: Equatable {
        case project(UUID)
        case progress
        case trash

        var help: LocalizedStringResource {
            switch self {
            case .project: "选择灵感、看这个项目的进展、项目操作"
            case .progress: "项目范围"
            case .trash: "清空回收站"
            }
        }
    }

    /// nil：这一页没有操作，不摆钮。
    private var content: Content? {
        switch workspace.mainRoute {
        case .project(let id): .project(id)
        case .progress: .progress
        case .trash: .trash
        default: nil
        }
    }

    var body: some View {
        if let content {
            Menu { items(content).labelStyle(.titleAndIcon) } label: { label(content) }
                .menuStyle(.button).menuIndicator(.hidden)
                .buttonStyle(ControlButtonStyle(kind: .circular))
                .fixedSize()
                .padding(.leading, leads ? 0 : Spacing.item)
                .help(content.help)
                .sensoryFeedback(.selection, trigger: workspace.scopedProject)
        }
    }

    @ViewBuilder private func label(_ content: Content) -> some View {
        if content == .progress {
            let current = workspace.catalog?.project(workspace.scopedProject)
            ProjectScopeLabel().menuLabel(current.map { "项目范围：\($0.shownName)" } ?? "项目范围：全部项目")
        } else {
            Image(.more).menuLabel("更多")
        }
    }

    @ViewBuilder private func items(_ content: Content) -> some View {
        switch content {
        case .project(let id): ProjectMenuItems(projectID: id)
        case .progress: ProjectScopePicker().pickerStyle(.inline)
        case .trash:
            Button("清空回收站…", icon: .trash, role: .destructive) { workspace.confirmsEmptyTrash = true }
        }
    }
}

extension View {
    /// 清空回收站的确认只此一份：宽屏栏头的"⋯"与手机页头的圆钮都只是把它打开（`Workspace.confirmsEmptyTrash`），挂在回收站页上。
    func emptyTrashConfirmation(_ workspace: Workspace) -> some View {
        dialog(
            "永久删除回收站里的全部内容？", isPresented: Bindable(workspace).confirmsEmptyTrash,
            message: "此操作无法撤销。发送记录会保留当时的内容快照。", buttons: [
            DialogButton(title: "清空回收站", role: .destructive) { workspace.perform { try await $0.emptyTrash() } }
        ])
    }
}
