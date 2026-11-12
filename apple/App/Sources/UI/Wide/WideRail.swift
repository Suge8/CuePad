import CueStore
import SwiftUI

/// 贴着窗口的边：底色从窗口顶一直铺到底（Mac 的红绿灯与开合钮坐在它上面），与主区只靠底色分开、不画分割线——
/// 同 macOS 27 的侧栏（WWDC26 主题演讲："Sidebars now expand to the very edges of the window. This helps reduce distractions along the left edge."）。
/// 只有开着、藏起两态（`Chrome` 头注释）：藏起时排版上宽 0；视图树一直挂着（滚动位置、读到的数都在），不放循环动效、点不到、读屏跳过，放回来不重建。
/// 藏起时它照原宽画在主区下面（主区铺满桌面色、盖住它）：开合时看得见的只有主区从它上面滑过（`WideColumnSlide`），它自己不动、不换样子。
/// 宽 `Chrome.rail`，不能拖：它是每个自动藏起临界宽的一项（`WideMetrics`），拖宽要么逐帧挪三栏（违背 Mac 开合不逐帧挪位置），要么只拖一条线、松手才变，换来的只是二十来点。
/// 被否决的：收起成一列图标条（`Chrome` 头注释）；浮起的一块（macOS 26 那样离窗边一档、圆角，红绿灯坐在里面）——四周一圈桌面色的缝分散左边的注意力，macOS 27 也改回贴边；
/// 开合钮与搜索放在会话条顶上一行（占一整行，搜索与会话条无关；搜索在最下一排的小钮里，主要靠 ⌘K）；开合钮做成玻璃圆钮（圆底压在会话条与主区的分界上）。
/// 进展那一行的图标是强调色（签名色靛青，HIG「Sidebars」："By default, sidebar icons use your app's accent color."）：是静止的符号、自成一组在会话的上面，
/// 与下面会动的靛青心电线、赭黄与胭脂的状态标靠形状和位置分开；会话行首只画状态标，不用强调色。
struct WideRail: View {
    let width: CGFloat
    #if os(iOS)
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
                RailCue()
                RailRow(title: "进展", icon: .task, selected: workspace.shownPane == .progress) { workspace.selectPane(.progress) }
            }
            RailSessions(data: services.liveSessions.rail, marked: Set(workspace.shownSessions.compactMap(\.sessionID))) { session, opening in
                workspace.openSession(session.id, sessionID: session.sessionID, in: opening == .beside ? .beside : .main)
            }
            #if os(macOS)
            tools
            #endif
        }
    }

    #if os(macOS)
    private var tools: some View {
        HStack(spacing: Spacing.tight) {
            RailTool(icon: .search, help: "搜索（⌘K）") { workspace.searching.toggle() }.disabled(!workspace.isLibraryReady)
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
