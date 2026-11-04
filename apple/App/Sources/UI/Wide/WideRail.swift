import CueStore
import SwiftUI

/// 宽屏左栏（会话条）：导航只在这一处。从上到下是顶上一排（Mac 是红绿灯那一排：搜索、侧栏钮）、项目与进展两行（与会话格同一种行、同一种选中底，
/// 选中是"主区此刻放的就是它"）、等你与推进中（`SessionRail`）、更早（`RailEarlier`），Mac 最底下一行图标（额度、技能与规则、设置）。
/// 宽 256，不能拖：它是每个自动收起临界宽的一项（`WideMetrics`），拖宽要么逐帧挪三栏（违背 Mac 开合不逐帧挪位置），要么只拖一条线、松手才变，换来的只是二十来点。
/// 收起是 80 的图标条（与红绿灯右沿对齐）：去处只剩图标，格子只剩 Agent 标志与状态记号，名字在悬停提示里（`railTip`）。图标条不放额度（同菜单栏面板那一份）。
/// 会话条上的图标钮不带玻璃：会话条是实底，玻璃圆钮放上去是两层；悬停、按下同行的淡底（`RowStyle`）。
struct WideRail: View {
    let width: CGFloat
    #if os(iOS)
    /// iPad 的 Cue 钮一直排在顶上那一排（`CueButton`）；Mac 的在窗口右上、只在 Cue 收着时有。
    var cue: (fits: Bool, shown: Bool)?
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var wide: Bool { width == SessionRail.Form.wide.width }

    /// 主区放的是项目｜进展的浏览落点（不是会话、辅助页）时，那一行才画选中底。
    private var browsing: Bool {
        guard case .wide(let navigation) = workspace.navigation, case .browse = navigation.main else { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 0) {
            top
            // 与会话格同一种行容器（`SessionRail.rowInset`）：选中底不越出栏边、不贴窗口边
            VStack(spacing: 2) {
                place("项目", icon: .folder, pane: .projects)
                place("进展", icon: .task, pane: .progress)
            }
            .padding(.horizontal, SessionRail.rowInset)
            .rowContainer(.rect(cornerRadius: Radius.block))
            .padding(.horizontal, SessionRail.Form.wide.inset)
            SessionRail(data: services.liveSessions.rail, form: wide ? .wide : .narrow,
                        marked: Set(workspace.shownSessions.compactMap(\.sessionID)), pulse: workspace.pulse) { session, opening in
                workspace.openSession(session.id, sessionID: session.sessionID, in: opening == .beside ? .beside : .main)
            }
            .padding(.top, 12)
            RailEarlier(wide: wide)
            #if os(macOS)
            tools
            #endif
        }
        .frame(width: width)
        .background(palette.sidebar)
    }

    @ViewBuilder private var top: some View {
        if wide {
            HStack(spacing: 2) {
                #if os(iOS)
                toggle
                Spacer(minLength: 0)
                search
                if let cue { CueButton(fits: cue.fits, shown: cue.shown) }
                #else
                Spacer(minLength: 0)
                search
                toggle
                #endif
            }
            .padding(.horizontal, 10)
            .frame(height: WideMetrics.band)
        } else if RailTop.current != .now {
            // PROTOTYPE 甲、乙：侧栏钮、搜索与下面的项目、进展同一列竖排、同一种格，顶上这一组与去处之间用间距分组
            #if os(macOS)
            Color.clear.frame(height: WideMetrics.band)
            #endif
            VStack(spacing: 2) { toggle; search }
                .environment(\.railColumn, true)
                .padding(.horizontal, SessionRail.rowInset)
                .rowContainer(.rect(cornerRadius: Radius.block))
                .padding(.horizontal, SessionRail.Form.wide.inset)
                .padding(.bottom, RailTop.groupGap)
            #if os(iOS)
            if let cue { CueButton(fits: cue.fits, shown: cue.shown).padding(.bottom, 6) }
            #endif
        } else {
            // 图标条：Mac 红绿灯那一排留给红绿灯，两颗钮排在它下面
            #if os(macOS)
            Color.clear.frame(height: WideMetrics.band)
            #endif
            HStack(spacing: 0) { toggle; search }.padding(.bottom, 6)
            #if os(iOS)
            if let cue { CueButton(fits: cue.fits, shown: cue.shown).padding(.bottom, 6) }
            #endif
        }
    }

    private var search: some View {
        #if os(macOS)
        RailIcon(icon: .search, help: "搜索（⌘K）") { workspace.searching.toggle() }
            .disabled(!workspace.isLibraryReady)
        #else
        RailIcon(icon: .search, help: "搜索") { workspace.openSearch() }
        #endif
    }

    private var toggle: some View {
        RailIcon(icon: .sidebar, help: "显示或隐藏侧栏（⌃⌘S）") { workspace.toggleSidebar() }
    }

    private func place(_ title: LocalizedStringResource, icon: Icon, pane: NavigationPane) -> some View {
        let selected = browsing && workspace.navigationPane == pane
        return Button { workspace.selectPane(pane) } label: {
            HStack(spacing: 8) {
                Image(icon).font(Glyph.control).foregroundStyle(palette.ink2).frame(width: 18)
                if wide {
                    Text(title).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, wide ? 8 : 0)
            .frame(maxWidth: .infinity, minHeight: wide ? RailIcon.row : RailIcon.side)
            .contentShape(.rect)
            .railTip(wide ? nil : String(localized: title))
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    #if os(macOS)
    /// 最底下一行：宽时左边额度（点开明细气泡），右边技能与规则、设置；图标条只有后两颗。归档、回收站在项目列表末尾（`ProjectShelf`），新建项目在项目列表顶上。
    private var tools: some View {
        HStack(spacing: 2) {
            if wide { SidebarQuota() } else { Spacer(minLength: 0) }
            RailIcon(icon: .instruction, help: "技能与规则") { workspace.show(.library) }
            RailIcon(icon: .settings, help: "设置（⌘,）") { SettingsPane.open() }
        }
        .padding(.horizontal, wide ? 10 : 0)
        .frame(height: RailIcon.toolsHeight)
    }
    #endif
}

/// 会话条上的图标钮：不带玻璃，悬停、按下同行的淡底（`WideRail` 头注释）。
struct RailIcon: View {
    let icon: Icon
    let help: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette
    @Environment(\.railColumn) private var column

    #if os(macOS)
    static let side: CGFloat = 30
    /// 项目、进展那两行的高（同会话格）。
    static let row = Spacing.sidebarRow
    /// Mac 会话条最底下那一行的高。
    static let toolsHeight: CGFloat = 44
    #else
    /// 手指点得到的最小一格（同系统 44）。
    static let side: CGFloat = 44
    static let row: CGFloat = 44
    #endif

    var body: some View {
        Button(action: action) {
            Image(icon).font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: column ? nil : Self.side, height: Self.side)
                .frame(maxWidth: column ? .infinity : nil)
                .contentShape(.rect)
        }
        .buttonStyle(.row)
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// PROTOTYPE（proto/head-phone2）：图标条顶上那一组（侧栏钮、搜索）的收口。
/// stack（甲）：图标条仍 80，两颗钮竖排、与项目、进展同一列同一种格。wide（乙）：同甲，图标条加宽到 98，红绿灯两侧留白相等。
enum RailTop: String {
    case now, stack, wide

    static let current = DebugHooks.preset.railTop
    /// 顶上这一组与下面的去处之间。
    static let groupGap: CGFloat = 12
}

extension EnvironmentValues {
    /// 图标钮排在会话条的一列里（PROTOTYPE `RailTop`）：格铺满列宽，同项目、进展两行。
    @Entry var railColumn = false
}

/// 会话条底部的"更早"：已结束的会话（宽屏的进展页没有会话一段，已结束的只在这里与 ⌘K 搜索），默认折起、只写个数，组头同等你、推进中那一种。
/// 宽时点组头原地展开成一列（Agent 标志、名字、多久前，最多占 `listHeight` 高、在里面滚，滚到底接着读下一页）；图标条上是"更早"与个数，点开是一份菜单（读到的那几页，末尾"显示更多"再读一页）。
/// 个数是全部已结束的会话，每一个都翻得到。
/// 点一行在主区打开（⌘ 点并排）。开合只在这一处，不进偏好：每次打开窗口都是折起的。
struct RailEarlier: View {
    let wide: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var open = false
    @State private var earlier: Earlier?
    /// 读到第几条为止：滚到列表底（宽）或点"显示更多"（图标条）再加一页。
    @State private var limit = PiSessionList.pageSize

    nonisolated struct Earlier: Equatable, Sendable {
        var items: [PiSessionState]
        var total: Int
        var hasMore: Bool { items.count < total }
    }

    private static let listHeight: CGFloat = 240

    var body: some View {
        let total = earlier?.total ?? 0
        Group {
            if wide {
                VStack(spacing: 2) {
                    header(total).padding(.horizontal, SessionRail.rowInset)
                    if open, let earlier {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(earlier.items, id: \.sessionID) { row($0) }
                                // 滑到这里才读下一页（同进展页会话段的分页）
                                if earlier.hasMore { Spinner(.small).frame(maxWidth: .infinity).padding(8).task(id: earlier.items.count) { more() } }
                            }
                            .padding(.horizontal, SessionRail.rowInset)
                        }
                        .frame(maxHeight: Self.listHeight)
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Menu {
                    ForEach(earlier?.items ?? [], id: \.sessionID) { session in
                        Button(session.title) { workspace.openSession(session.id, sessionID: session.sessionID) }
                    }
                    if earlier?.hasMore == true {
                        Divider()
                        Button("显示更多") { more() }
                    }
                } label: {
                    VStack(spacing: 0) {
                        Text("更早").foregroundStyle(palette.ink2)
                        Text(total, format: .number).foregroundStyle(palette.ink3).monospacedDigit()
                    }
                    .font(Typography.caption.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: 40)
                    .contentShape(.rect)
                }
                .menuStyle(.button).buttonStyle(.row).menuIndicator(.hidden)
                .disabled(total == 0)
                .accessibilityLabel(Text("更早"))
                .accessibilityValue(Text(total, format: .number))
                .padding(.horizontal, SessionRail.rowInset)
            }
        }
        // 同会话格的行容器（`SessionRail.rowInset`）
        .rowContainer(.rect(cornerRadius: Radius.block))
        .padding(.horizontal, SessionRail.Form.wide.inset)
        .padding(.top, 6)
        .observing(services.store, id: limit, into: $earlier, onError: workspace.fail) { [limit] store in
            let page = try store.piSessionPage(PiSessionQuery(scope: .ended, limit: limit))
            return Earlier(items: page.items.map(\.listed), total: page.total)
        }
    }

    private func more() {
        if let earlier, earlier.hasMore { limit = earlier.items.count + PiSessionList.pageSize }
    }

    private func header(_ total: Int) -> some View {
        Button { withAnimation(Motion.fade) { open.toggle() } } label: {
            HStack(spacing: 4) {
                Text("更早").foregroundStyle(palette.ink2)
                Text(total, format: .number).foregroundStyle(palette.ink3).monospacedDigit()
                Spacer(minLength: 0)
                Image(open ? .collapse : .expand).font(Glyph.mark).foregroundStyle(palette.ink3)
            }
            .font(Typography.caption.weight(.semibold))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(.row)
        .disabled(total == 0)
        .accessibilityAddTraits(.isHeader)
        .accessibilityValue(Text(total, format: .number))
        .accessibilityHint(open ? "收起" : "展开")
    }

    private func row(_ session: PiSessionState) -> some View {
        Button { open(session) } label: {
            HStack(spacing: 8) {
                Group { if let agent = session.agent.known { agent.mark.image } else { Image(.terminal) } }
                    .font(Glyph.control).foregroundStyle(palette.ink3).frame(width: 18)
                    .accessibilityHidden(true)
                Text(verbatim: session.title).font(Typography.body).foregroundStyle(palette.ink2).lineLimit(1)
                Spacer(minLength: 4)
                Text(session.stateSince, format: .relative(presentation: .named, unitsStyle: .abbreviated))
                    .font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1)
            }
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30)
            .contentShape(.rect)
        }
        .buttonStyle(RowStyle(selected: workspace.shownSessions.contains { $0.sessionID == session.sessionID }))
        .contextMenu { Button("在旁边打开") { open(session, beside: true) } }
    }

    private func open(_ session: PiSessionState, beside: Bool = false) {
        #if os(macOS)
        let beside = beside || NSApp.currentEvent?.modifierFlags.contains(.command) == true
        #endif
        workspace.openSession(session.id, sessionID: session.sessionID, in: beside ? .beside : .main)
    }
}

/// 收起的会话条（80）上一行的名字：指针停在行上时浮在行的右边，整窗一层画（`railTips`），不挤排版、不被会话条裁掉；系统的提示要等一秒多，这里一停就出。
/// 指针停没停读的是行底给的 `rowHovered`（挂在 `RowStyle` 或 `row()` 的内容上），不另挂 `onHover`。`text` 为 nil 时不出（宽版有名字）。
nonisolated struct RailTip: Equatable {
    let text: String
    let anchor: Anchor<CGRect>
}

private struct RailTipKey: PreferenceKey {
    static let defaultValue: RailTip? = nil
    static func reduce(value: inout RailTip?, nextValue: () -> RailTip?) { value = value ?? nextValue() }
}

extension View {
    func railTip(_ text: String?) -> some View { modifier(RailTipSource(text: text)) }

    /// 宽屏窗口的根上：把收起的会话条报上来的悬停名字画在行的右边。
    func railTips() -> some View {
        overlayPreferenceValue(RailTipKey.self) { tip in
            GeometryReader { proxy in
                if let tip { RailTipLabel(text: tip.text, frame: proxy[tip.anchor]) }
            }
        }
    }
}

private struct RailTipSource: ViewModifier {
    let text: String?
    @Environment(\.rowHovered) private var hovered

    func body(content: Content) -> some View {
        content.anchorPreference(key: RailTipKey.self, value: .bounds) { anchor in
            if hovered, let text { RailTip(text: text, anchor: anchor) } else { nil }
        }
    }
}

private struct RailTipLabel: View {
    let text: String
    let frame: CGRect
    @Environment(\.palette) private var palette

    var body: some View {
        Text(verbatim: text)
            .font(Typography.secondary.weight(.medium))
            .foregroundStyle(palette.ink)
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .paper(cornerRadius: Radius.block, lifted: true)
            .offset(x: frame.maxX + RowMetrics.bleed + 6, y: frame.midY - Self.height / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private static let height: CGFloat = 30
}
