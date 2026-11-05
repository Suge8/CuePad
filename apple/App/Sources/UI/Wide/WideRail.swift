import CueStore
import SwiftUI

/// 宽屏左栏（会话条）：导航只在这一处。从上到下是去处（项目、进展、更早，选中是"主区此刻放的就是它"）、等你与推进中（`SessionRail`）、
/// Mac 最底下一行（技能与规则、设置、额度）；iPad 顶上一排是侧栏钮、搜索、Cue 钮。尺寸全在 `Chrome`，行的组件在 `RailRows.swift`。
/// 贴着窗口的边：底色从窗口顶一直铺到底（Mac 的红绿灯与开合钮坐在它上面），与主区只靠底色分开、不画分割线——
/// 同 macOS 27 的侧栏（WWDC26 主题演讲："Sidebars now expand to the very edges of the window. This helps reduce distractions along the left edge."）。
/// 只有开着、藏起两态（`Chrome` 头注释）：藏起时排版上宽 0；视图树一直挂着（滚动位置、读到的数都在），不放循环动效、点不到、读屏跳过，放回来不重建。
/// 藏起时它照原宽画在主区下面（主区铺满桌面色、盖住它）：开合时看得见的只有主区从它上面滑过（`WideColumnSlide`），它自己不动、不换样子。
/// 藏起后注意力不丢：开合钮角上一颗点说有没有在等你（`SidebarToggle`），Cue 的名牌写着数字账，看板也在。
/// Mac 的开合钮在窗口最顶那一排、红绿灯右边（`SidebarToggle`），开着藏起都不动；搜索是这一页的操作，在主区栏头右端（`SearchSlot`）。
/// iPad 顶上那一排藏起时原地浮成玻璃圆钮（`RailTopTools`，位置不动），主区栏头让出它们。
/// 宽 `Chrome.rail`，不能拖：它是每个自动藏起临界宽的一项（`WideMetrics`），拖宽要么逐帧挪三栏（违背 Mac 开合不逐帧挪位置），要么只拖一条线、松手才变，换来的只是二十来点。
/// 被否决的：收起成一列图标条（`Chrome` 头注释）；浮起的一块（macOS 26 那样离窗边一档、圆角，红绿灯坐在里面）——四周一圈桌面色的缝分散左边的注意力，macOS 27 也改回贴边；
/// 开合钮与搜索放在会话条顶上一行（占一整行，搜索与会话条无关）；开合钮做成玻璃圆钮（圆底压在会话条与主区的分界上）。
/// 项目、进展、更早三行的图标是强调色（签名色靛青，HIG「Sidebars」："By default, sidebar icons use your app's accent color."）：是静止的符号、自成一组在会话的上面，
/// 与下面会动的靛青心电线、赭黄与胭脂的状态标靠形状和位置分开；会话行首只画状态标，不用强调色。
struct WideRail: View {
    /// 此刻的宽：`Chrome.rail` 或藏起的 0。
    let width: CGFloat
    #if os(iOS)
    /// iPad 顶上那一排（侧栏钮、搜索、Cue 钮，`RailTopTools`）按窗口此刻的尺寸开合；Mac 的开合钮在最顶那一排、Cue 钮在窗口右上。
    var sizes: WideMetrics?
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @Environment(\.pageActive) private var active

    private var shown: Bool { width > 0 }

    var body: some View {
        rows
            #if os(macOS)
            .padding(.top, Chrome.band)
            .padding(.bottom, Spacing.item)
            #endif
            .padding(.horizontal, Chrome.gutter)
            .frame(width: Chrome.rail)
            .frame(maxHeight: .infinity, alignment: .top)
            // 直角：贴着窗口的边，四角由窗口自己的圆角裁
            .rowContainer(.rect)
            .environment(\.rowSurface, palette.sidebar)
            .background { palette.sidebar.ignoresSafeArea() }
            .environment(\.pageActive, active && shown)
            .frame(width: width, alignment: .leading)
            .allowsHitTesting(shown)
            .readerHidden(!shown)
    }

    private var rows: some View {
        VStack(spacing: Chrome.groupGap) {
            #if os(iOS)
            if let sizes { RailTopTools(sizes: sizes, floating: false) }
            #endif
            RailGroup {
                RailRow(title: "项目", icon: .folder, selected: workspace.shownPane == .projects) { workspace.selectPane(.projects) }
                RailRow(title: "进展", icon: .task, selected: workspace.shownPane == .progress) { workspace.selectPane(.progress) }
                RailEarlier()
            }
            SessionRail(data: services.liveSessions.rail, form: .wide,
                        marked: Set(workspace.shownSessions.compactMap(\.sessionID)), pulse: workspace.pulse) { session, opening in
                workspace.openSession(session.id, sessionID: session.sessionID, in: opening == .beside ? .beside : .main)
            }
            #if os(macOS)
            tools
            #endif
        }
    }

    #if os(macOS)
    /// 最底下一行：技能与规则、设置两颗无底图标钮（`RailTool`），图标正在行首那一列上；额度靠右，右沿同行尾的读数（点开明细气泡；藏起时额度在菜单栏面板）。
    /// 归档、回收站在项目列表末尾（`ProjectShelf`），新建项目在项目列表顶上。
    private var tools: some View {
        HStack(spacing: Spacing.tight) {
            RailTool(icon: .instruction, help: "技能与规则") { workspace.show(.library) }
            RailTool(icon: .settings, help: "设置（⌘,）") { SettingsPane.open() }
            Spacer(minLength: 0)
            SidebarQuota()
        }
        // 两颗钮的圆比行首那一列宽：往左让出多出来的一半，图标正在那一列的中线上；额度的右沿落在行尾读数那条线（行底让出的那一截）
        .padding(.leading, RowMetrics.bleed - (ControlSize.compact.height - Chrome.icon) / 2)
        .padding(.trailing, RowMetrics.bleed)
        .frame(height: Chrome.control)
    }
    #endif
}

#if os(iOS)
/// iPad 会话条顶上那一排：侧栏钮、搜索、Cue 钮，左沿在行首那一列（`Chrome.lead`）。会话条开着时是会话条上平放的格（`RailIcon`）；
/// 藏起时同一排原地浮在内容上（`floating`，玻璃圆钮，同页顶那一排），三颗钮一点不挪——主区栏头让出它们（`Chrome.headLead`）；侧栏钮角上同 Mac 的开合钮带等你的点（`railWaitingDot`）。
struct RailTopTools: View {
    let sizes: WideMetrics
    let floating: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: Spacing.item) {
            tool(.sidebar, "显示或隐藏侧栏（⌃⌘S）") { workspace.toggleRail(sizes) }
                .railWaitingDot(hidden: !workspace.railShown(sizes))
            tool(.search, "搜索") { workspace.openSearch() }
            CueButton(fits: sizes.cueFits, shown: workspace.cueShown(sizes)).frame(width: Chrome.control, height: Chrome.control)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, floating ? Chrome.lead : RowMetrics.bleed)
    }

    @ViewBuilder private func tool(_ icon: Icon, _ help: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        if floating {
            Button(help, icon: icon, action: action)
                .labelStyle(.iconOnly)
                .buttonStyle(ControlButtonStyle(kind: .circular))
        } else {
            RailIcon(icon: icon, help: help, action: action)
        }
    }
}
#endif
