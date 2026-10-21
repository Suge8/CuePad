#if os(iOS)
import CueStore
import SwiftUI
import UIKit

extension View {
    /// 列表与表单铺在桌面色上，与书架、项目页同一底色。
    func deskBackground() -> some View { modifier(DeskBackground()) }

    /// 长按项目（书架、侧栏）：抬起这一项作预览，菜单是共用的项目操作，有 Pi 会话时菜单标题写明它的状态
    /// （说清旁边那个点是什么意思）。项目还没同步到（nil）时没有菜单。
    func projectActions(_ project: Project?, radius: CGFloat, pi: PiShown?) -> some View {
        modifier(ProjectContextMenu(project: project, radius: radius, pi: pi))
    }
}

extension View {
    /// 长按菜单带一块浮起的预览（长按预览只经这里）。预览由系统另起一层宿主来排，不继承这里的环境：
    /// 预览里的行读窗口级的对象（`Workspace`、`AppServices`）时缺了就是 fatalError，调色板缺了按浅色画。
    /// 这里把 `IOSRoot` 在最外层注入的那几样原样带进去，各处的预览不再自己补。
    func contextMenu<Menu: View, Preview: View>(
        @ViewBuilder menu: @escaping () -> Menu, @ViewBuilder lifting preview: @escaping () -> Preview
    ) -> some View {
        modifier(LiftedContextMenu(menu: menu, preview: preview))
    }
}

private struct LiftedContextMenu<Menu: View, Preview: View>: ViewModifier {
    let menu: () -> Menu
    let preview: () -> Preview
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.cardAgents) private var agents

    func body(content: Content) -> some View {
        content.contextMenu(menuItems: menu) {
            preview()
                .environment(workspace)
                .environment(services)
                .environment(\.palette, palette)
                .tint(palette.ink)
                .environment(\.cardAgents, agents)
        }
    }
}

private struct ProjectContextMenu: ViewModifier {
    let project: Project?
    let radius: CGFloat
    let pi: PiShown?

    func body(content: Content) -> some View {
        if let project {
            content
                .contentShape(.contextMenuPreview, .rect(cornerRadius: radius, style: .continuous))
                .contextMenu {
                    let actions = ProjectActions(project: project) { workspace.projectForm = .init(project: project) }
                    if let pi { Section(pi.presence) { actions } } else { actions }
                }
        } else {
            content
        }
    }
    @Environment(Workspace.self) private var workspace
}

private struct DeskBackground: ViewModifier {
    @Environment(\.palette) private var palette
    func body(content: Content) -> some View { content.scrollContentBackground(.hidden).background(palette.desk) }
}

#endif
