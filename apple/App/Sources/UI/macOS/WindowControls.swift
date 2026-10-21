#if os(macOS)
import CueStore
import SwiftUI

/// 内容区工具栏最左：侧栏收起时的项目切换（紧跟在侧栏钮后面）。同一个工具栏项里增减（增删工具栏项会重排整条工具栏）。
/// 单独一个视图读侧栏开合：主窗口的视图体读了它，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
struct SwitcherSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let collapsed = workspace.pages.sidebar == .detailOnly
        // 一直挂着（收起时才有宽度）：开合侧栏的那一刻不再现建全部项目的菜单。不用 disabled：环境一变整份菜单又要重算；
        // ⌘1–9 本来就由窗口快捷键（`WorkspaceShortcuts`）接，菜单里的只是提示
        ProjectSwitcher(collapsed: collapsed)
            .frame(width: collapsed ? nil : 0, alignment: .leading)
            .clipped()
            .opacity(collapsed ? 1 : 0)
            .accessibilityHidden(!collapsed)
    }
}

/// 开合侧栏（`MacPages.toggleSidebar`，⌃⌘S 同）。收起时侧栏的 Cue 名片看不见了：不在 Cue 页、Cue 有等你或新消息时钮角上带点（`CueDot`）。
struct SidebarToggle: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        // 点画在标签里：工具栏把"字 + 图标"的标签换成系统按钮，挂在按钮外面的会被丢掉
        Button { workspace.pages.toggleSidebar() } label: {
            Image(.sidebar).overlay(alignment: .topTrailing) {
                if workspace.pages.sidebar == .detailOnly, workspace.page != .cue { CueDot().offset(x: 5, y: -4) }
            }
        }
        .accessibilityLabel("侧栏")
        .help("显示或隐藏侧栏（⌃⌘S）")
    }
}

/// 打开、收起卡片只改动下面三处（收起按钮、编辑页图层、底部输入条的位置），各自读"打开的卡"：
/// 主窗口的视图体不读它，开合时不重算整个窗口、不重建整条工具栏。

/// 工具栏左上的"收起"：只在开着编辑页时有（Esc 同）。工具栏项常驻、只有里面的按钮出没（增删工具栏项会重建整条工具栏）；
/// 没有编辑页时它不占位置。
struct CloseButton: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.openCard != nil {
            Button { workspace.openCard = nil } label: {
                HStack(spacing: 4) {
                    Image(.back).font(.system(size: 13, weight: .semibold))
                    Text("收起")
                }
            }
            .buttonStyle(ControlButtonStyle(kind: .glass))
            .keyboardShortcut(.cancelAction)
            .help("收起（Esc）")
        }
    }
}

/// 工具栏左边、侧栏钮（与侧栏收起时的项目切换）之后：这一页的范围，任务页是项目范围（`ProjectScopeMenu`）。
/// 每页都在、固定宽度，别的页看不见（不卸下）：工具栏项一增删整条重建、一变尺寸整条重排并重算整窗的鼠标跟踪区（同 `PageMenuSlot`、会话页标题项），
/// 所以项目名长了在这一格里截断，不撑宽它。
struct ScopeSlot: View {
    @Environment(Workspace.self) private var workspace

    static let width: CGFloat = 200

    var body: some View {
        let shown = workspace.page == .tasks
        // 一直挂着、别的页只是看不见（同 `SwitcherSlot`）：换页时不现建整份项目菜单
        ProjectScopeMenu(maxWidth: Self.width)
            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
            .frame(width: Self.width, height: Spacing.toolbarControl, alignment: .leading)
    }
}

/// 工具栏右边、搜索之前：这一页的主操作，任务页是"新任务"（待办顶上浮出添加那一行，`Workspace.addsTask`）。
/// 同 `ScopeSlot`：每页都在、固定宽度，别的页看不见。
struct PageActionSlot: View {
    @Environment(Workspace.self) private var workspace

    static let width: CGFloat = 96

    var body: some View {
        let shown = workspace.page == .tasks
        // 工具栏把"图标 + 字"的标签只画成图标：写明两样都要
        Button("新任务", icon: .add) { workspace.addsTask.toggle() }
            .labelStyle(.titleAndIcon)
            .buttonStyle(ControlButtonStyle(kind: .glass))
            .help("在待办里添加任务")
            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
            .frame(width: Self.width, height: Spacing.toolbarControl, alignment: .trailing)
    }
}
#endif
