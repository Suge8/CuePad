#if os(iOS)
import SwiftUI

/// 窄屏（iPhone 与窄窗口 iPad）的容器：系统标签栏（`TabView`）上项目、进展、Cue 三个 tab（`Dock.tabs`），每个 tab 一个导航栈（`Workspace.stacks`）。
/// 切走再切回来还停在原来那一页：页不重建，滚动位置、没写完的字都在。点标签栏只换 tab（`Workspace.root`），再点一下选中的 tab 回到它的根（系统的）；
/// 别的入口（快捷键、提示、深链）经 `Workspace.select` 去所属 tab 上的那一页。推入、返回、切 tab 的过渡都是系统的：往深处从右推入，返回往右退，切 tab 原地换。
/// 推入的页上标签栏照样在（写着灵感也能切去 Cue 看一眼），设置、技能与说明这类二级页让开（`Dock.showsTabBar`）。
/// 不在前台的 tab 暂停订阅（`pageActive`）；打开 App 落在 Cue。
struct DockRoot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var workspace = workspace
        let root = workspace.root
        TabView(selection: $workspace.root) {
            Tab(value: Route.shelf) {
                DockStack(tab: .shelf, active: root == .shelf)
            } label: {
                DockTabLabel(tab: .shelf, selected: root == .shelf)
            }
            Tab(value: Route.progress) {
                DockStack(tab: .progress, active: root == .progress)
            } label: {
                DockTabLabel(tab: .progress, selected: root == .progress)
            }
            Tab(value: Route.cue) {
                DockStack(tab: .cue, active: root == .cue)
            } label: {
                DockTabLabel(tab: .cue, selected: root == .cue)
            }
            .badge(workspace.cue.unread)
        }
        .tint(palette.signature)
        .overlay { DockRelaySpots(shown: Dock.showsTabBar(on: workspace.top)) }
    }
}

/// 一个 tab：根页自己画页顶那一排（系统导航栏只给推入的页，`HeaderHost.page`），推入的页按 `Dock.showsTabBar` 留不留标签栏。
private struct DockStack: View {
    let tab: Route
    let active: Bool
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let path = workspace.stacks[tab] ?? []
        NavigationStack(path: Binding(get: { path }, set: { workspace.stacks[tab] = $0 })) {
            RouteView(route: tab)
                .environment(\.headerHost, .page(search: Dock.search(on: tab)))
                .toolbarVisibility(.hidden, for: .navigationBar)
                .navigationDestination(for: Route.self) { route in
                    RouteView(route: route).toolbarVisibility(Dock.showsTabBar(on: route) ? .automatic : .hidden, for: .tabBar)
                }
        }
        .environment(\.pageActive, active)
    }
}

/// 接力落在标签栏上的两处：Cue 那一格（`CueSpot.dock`）与"进展"那一格（`EndSpot.dock`，会话哪一行都不在屏上时）。
/// 标签栏是系统的，格子在哪按它的排法推（`Dock.cell`）；标签栏让开（二级页）或被键盘盖住时不挂。
private struct DockRelaySpots: View {
    let shown: Bool

    var body: some View {
        GeometryReader { proxy in
            // 键盘起来时下安全区是键盘高，标签栏在它底下
            if shown, proxy.safeAreaInsets.bottom < Dock.height {
                let bottom = proxy.size.height + proxy.safeAreaInsets.bottom
                ZStack {
                    spot(Dock.cell(Dock.tabs.firstIndex(of: .cue) ?? 0, in: proxy.size.width, bottom: bottom)).relaySpot(cue: .dock)
                    spot(Dock.cell(Dock.tabs.firstIndex(of: .progress) ?? 0, in: proxy.size.width, bottom: bottom)).relaySpot(dock: true)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func spot(_ cell: CGRect) -> some View {
        Color.clear.frame(width: cell.width, height: cell.height).position(x: cell.midX, y: cell.midY)
    }
}

enum Dock {
    /// 标签栏上从左到右的三个 tab：项目、进展、Cue（进展挨着 Cue：会话在进展里，接力的光从 Cue 落到它那一格最近）。
    static let tabs: [Route] = [.shelf, .progress, .cue]
    /// 系统悬浮标签栏（iOS 27 iPhone 实测）：三格排在屏幕正中，相邻两格的中心隔 86 点；栏高 62、离屏幕底边 21，格子上下各让 4。
    /// 系统改了排法接力就落偏，大版本升级时核对（读屏树里标签页栏的三颗按钮）。
    static let height: CGFloat = 62
    private static let margin: CGFloat = 21
    private static let inset: CGFloat = 4
    private static let pitch: CGFloat = 86

    /// 第 index 格在窗口里的位置（`bottom`：屏幕底边离这一层顶上多远）。
    static func cell(_ index: Int, in width: CGFloat, bottom: CGFloat) -> CGRect {
        let midX = width / 2 + (CGFloat(index) - CGFloat(tabs.count - 1) / 2) * pitch
        return CGRect(x: midX - pitch / 2, y: bottom - margin - height + inset, width: pitch, height: height - inset * 2)
    }

    /// tab 根页页顶那一排的搜索入口：项目页中间没有别的，是铺满的一条搜索框；进展页中间放着这一页看什么，是左边一颗圆钮；
    /// Cue 页的焦点就是 Cue，没有。提示横幅按它决定盖多宽（`NoticeBanner`）。
    static func search(on route: Route) -> HeaderSearch? {
        switch route {
        case .shelf: .field
        case .progress: .button
        default: nil
        }
    }

    /// 这一页上留不留着标签栏：往下钻的页都留着（项目、灵感、会话……，切 tab 随时点得到）；设置、技能与说明这类二级页让开，同系统设置里的子页。
    static func showsTabBar(on route: Route) -> Bool {
        switch route {
        case .settings, .conflicts, .library, .libraryItem: false
        default: true
        }
    }
}
#endif
