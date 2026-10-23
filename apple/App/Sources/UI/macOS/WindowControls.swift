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
            // 不跟着侧栏的动画变宽：工具栏项每帧变一次宽，整条工具栏就每帧重新约束一遍
            .animation(nil, value: collapsed)
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
                if workspace.pages.sidebar == .detailOnly, workspace.root != .cue { CueDot().offset(x: 5, y: -4) }
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

/// 工具栏左边、侧栏钮（与侧栏收起时的项目切换）之后：这一页的范围，进展页（看板与会话两段）是项目范围（`ProjectScopeMenu`，`Workspace.projectScope`）。
/// 工具栏里的页面控件只有一条规矩（这一格、`PageActionSlot`、`PageMenuSlot` 都照它）：只放 Workspace 里已有的状态，主窗口里常驻、固定宽度、只换内容。
/// 工具栏项挂在主窗口上，读不到页面读的库，抄一份过来就是第二个事实源；工具栏项一增删整条重建（实测占进出会话页点击回合的一半，25fdb5fa、4fd371a4），
/// 一变尺寸整条重排、重算整窗的鼠标跟踪区（100～150ms，b9707fc5）。所以每页都在，别的页看不见、不卸下（换页时不现建整份项目菜单），
/// 项目名长了在这一格里截断，不撑宽它；状态归页面的（会话段的搜索、新会话表单读的这台 Mac 上有哪些 Agent）留在页里。
struct ScopeSlot: View {
    @Environment(Workspace.self) private var workspace

    static let width: CGFloat = 200

    var body: some View {
        let shown = workspace.root == .progress
        // 一直挂着、别的页只是看不见（同 `SwitcherSlot`）：换页时不现建整份项目菜单
        ProjectScopeMenu()
            .frame(maxWidth: Self.width, alignment: .leading)
            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
            .frame(width: Self.width, height: Spacing.toolbarControl, alignment: .leading)
    }
}

/// 工具栏右边、主操作之前：进展页的额度环（`QuotaRings`，点它从环下长出明细的气泡 `QuotaDetail`）。额度是整个 App 的（`AppServices.accountQuotas`），
/// 不是哪一页读的库，照 `ScopeSlot` 的规矩常驻、固定宽度，别的页看不见。
struct QuotaSlot: View {
    @Environment(Workspace.self) private var workspace
    @State private var open = DebugHooks.preset.quotaOpen
    /// 收起的时刻：按在环上收起的，松开时不再打开（`PressPoint.reopens`）。
    @State private var closed: ContinuousClock.Instant?

    /// 三颗环（`QuotaRings` 至多三个账号）的宽。
    static let width: CGFloat = 92

    var body: some View {
        let shown = workspace.root == .progress
        QuotaRings(open: open, height: Spacing.toolbarControl) { open = !open && !PressPoint.reopens(closedAt: closed) }
            .glass(in: .capsule, interactive: true)
            .bubble(isPresented: $open) { QuotaDetail().padding(16) }
            .onChange(of: open) { _, open in if !open { closed = .now } }
            .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
            .frame(width: Self.width, height: Spacing.toolbarControl, alignment: .trailing)
    }
}

/// 工具栏右边、搜索之前：这一页的主操作，进展页随段换：看板是"新任务"（待办顶上浮出添加那一行，`Workspace.addsTask`），
/// 会话是"新会话"（弹出新会话的表单，`NewSessionPanel`）。规矩同 `ScopeSlot`：每页都在、固定宽度，别的页看不见。
struct PageActionSlot: View {
    @Environment(Workspace.self) private var workspace

    static let width: CGFloat = 96

    var body: some View {
        let shown = workspace.root == .progress, sessions = workspace.progressPane == .sessions
        // 工具栏把"图标 + 字"的标签只画成图标：写明两样都要
        Button(sessions ? "新会话" : "新任务", icon: .add) {
            if sessions { workspace.showsNewSession = true } else { workspace.addsTask.toggle() }
        }
        .labelStyle(.titleAndIcon)
        .buttonStyle(ControlButtonStyle(kind: .glass))
        .help(sessions ? "开一个新的 Agent 会话（⌥⌘N）" : "在待办里添加任务")
        .opacity(shown ? 1 : 0).allowsHitTesting(shown).accessibilityHidden(!shown)
        .frame(width: Self.width, height: Spacing.toolbarControl, alignment: .trailing)
    }
}
#endif
