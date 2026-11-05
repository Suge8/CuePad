import CueStore
import SwiftUI

/// 宽屏左栏（会话条）：导航只在这一处。从上到下是顶上那一组（侧栏钮、搜索；iPad 还有 Cue 钮）、项目与进展（选中是"主区此刻放的就是它"）、
/// 等你与推进中（`SessionRail`）、更早，Mac 最底下一行（技能与规则、设置、额度）。尺寸全在 `Chrome`。
/// 收起与展开同一套排法（`Chrome` 头注释）：每一行行首是一格（图标），名字在它右边，收起时淡去、名字改在悬停提示里（`railTip`）；
/// Mac 红绿灯那一排两种宽都空着留给红绿灯。展开时多出来的只有名字、个数与额度，格一个都不挪。
/// 宽 `Chrome.rail`，不能拖：它是每个自动收起临界宽的一项（`WideMetrics`），拖宽要么逐帧挪三栏（违背 Mac 开合不逐帧挪位置），要么只拖一条线、松手才变，换来的只是二十来点。
/// 会话条上的钮不带玻璃：会话条是一整块实底的栏，钮平放在上面，悬停、按下同行的淡底（`RowStyle`）；玻璃圆钮留给浮在内容上的栏头。
struct WideRail: View {
    let width: CGFloat
    #if os(iOS)
    /// iPad 的 Cue 钮一直排在顶上那一组（`CueButton`）；Mac 的在窗口右上、只在 Cue 收着时有。
    var cue: (fits: Bool, shown: Bool)?
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var wide: Bool { width == Chrome.rail }

    var body: some View {
        if DebugHooks.railProto {
            #if os(iOS)
            RailProto(width: width, cue: cue)
            #else
            RailProto(width: width)
            #endif
        } else {
            current
        }
    }

    private var current: some View {
        VStack(spacing: Chrome.groupGap) {
            #if os(macOS)
            Color.clear.frame(height: Chrome.band - Chrome.groupGap)
            #endif
            RailGroup {
                RailIcon(icon: .sidebar, help: "显示或隐藏侧栏（⌃⌘S）") { workspace.toggleSidebar() }
                search
                #if os(iOS)
                if let cue { CueButton(fits: cue.fits, shown: cue.shown).frame(width: Chrome.control, height: Chrome.control) }
                #endif
            }
            RailGroup {
                RailRow(title: "项目", icon: .folder, selected: workspace.shownPane == .projects, wide: wide) { workspace.selectPane(.projects) }
                RailRow(title: "进展", icon: .task, selected: workspace.shownPane == .progress, wide: wide) { workspace.selectPane(.progress) }
            }
            SessionRail(data: services.liveSessions.rail, form: wide ? .wide : .narrow,
                        marked: Set(workspace.shownSessions.compactMap(\.sessionID)), pulse: workspace.pulse) { session, opening in
                workspace.openSession(session.id, sessionID: session.sessionID, in: opening == .beside ? .beside : .main)
            }
            RailEarlier(wide: wide)
            #if os(macOS)
            tools
            #endif
        }
        .frame(width: width)
        .background(palette.sidebar)
    }

    private var search: some View {
        #if os(macOS)
        RailIcon(icon: .search, help: "搜索（⌘K）") { workspace.searching.toggle() }
            .disabled(!workspace.isLibraryReady)
        #else
        RailIcon(icon: .search, help: "搜索") { workspace.openSearch() }
        #endif
    }

    #if os(macOS)
    /// 最底下一行：技能与规则、设置两格并排在中轴两边，展开时右边接着额度（点开明细气泡；收起时额度在菜单栏面板）。
    /// 归档、回收站在项目列表末尾（`ProjectShelf`），新建项目在项目列表顶上。
    private var tools: some View {
        HStack(spacing: Chrome.cellGap) {
            RailIcon(icon: .instruction, help: "技能与规则") { workspace.show(.library) }
            RailIcon(icon: .settings, help: "设置（⌘,）") { SettingsPane.open() }
            if wide { SidebarQuota() }
            Spacer(minLength: 0)
        }
        .padding(.leading, (Chrome.strip - 2 * Chrome.control - Chrome.cellGap) / 2)
        .padding(.bottom, Chrome.pad)
    }
    #endif
}

/// 会话条上的一组（顶上那几颗钮、项目与进展、更早）：左沿在 `Chrome.edge`，右沿跟着会话条的宽；里面的行与格靠左排，行首那一格在条的中轴上。
/// 等你与推进中的纸同这一套（`SessionRail`）。
struct RailGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Chrome.cellGap) { content }.modifier(RailGroupModifier())
    }
}

struct RailGroupModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Chrome.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowContainer(.rect(cornerRadius: Radius.block))
            .padding(.horizontal, Chrome.edge)
    }
}

/// 会话条上的一行：行首一格（`lead`，`Chrome.control` 见方），右边是名字等（`rest`），收起时淡去、行就只剩那一格。
/// 名字叠在行上、不参与排版：收起时它要的最小宽（省略号、行尾留白）会把行撑宽，整组跟着往左偏。
struct RailLine<Lead: View, Rest: View>: View {
    let wide: Bool
    /// 组头矮一些（`Chrome.groupHeader`）。
    var height = Chrome.control
    @ViewBuilder let lead: Lead
    @ViewBuilder let rest: Rest

    var body: some View {
        lead.frame(width: Chrome.control, height: height)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: Spacing.tight) { rest }
                    .padding(.leading, Chrome.control)
                    .padding(.trailing, Spacing.item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(wide ? 1 : 0)
            }
            .clipped()
        .contentShape(.rect)
    }
}

/// 项目、进展：图标与名字的一行；收起时名字在悬停提示里。
private struct RailRow: View {
    let title: LocalizedStringResource
    let icon: Icon
    let selected: Bool
    let wide: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            RailLine(wide: wide) {
                Image(icon).font(Glyph.control).foregroundStyle(selected ? palette.ink : palette.ink2)
            } rest: {
                Text(title).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
            }
            .railTip(wide ? nil : String(localized: title))
        }
        .buttonStyle(RowStyle(selected: selected, cell: true))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// 会话条上的图标钮：一格（`Chrome.control` 见方），不带玻璃，悬停、按下是这一格的淡底（`WideRail` 头注释）。
struct RailIcon: View {
    let icon: Icon
    let help: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(icon).font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: Chrome.control, height: Chrome.control)
                .contentShape(.rect)
        }
        .buttonStyle(RowStyle(cell: true))
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}

/// 会话条上的"更早"：已结束的会话（`PiSessionList.earlier`，正在唤醒的在推进中；已结束的只在这里与搜索），同项目、进展一种行，写个数。
/// 点它在主区打开"更早"那一页（`Route.earlier`，`EarlierPage`，三端同一页）；个数与那一页读同一个查询，两边对得上。没有已结束的会话时置灰。
struct RailEarlier: View {
    let wide: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var total: Int?

    var body: some View {
        let total = total ?? 0
        let selected = workspace.mainRoute == .earlier
        RailGroup {
            Button { workspace.show(.earlier) } label: {
                RailLine(wide: wide) {
                    Image(.session).font(Glyph.control).foregroundStyle(selected ? palette.ink : palette.ink2)
                } rest: {
                    Text("更早").font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                    Spacer(minLength: 0)
                    Text(total, format: .number).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
                }
                .railTip(wide ? nil : Dotted(String(localized: "更早"), total.formatted()).visible)
            }
            .buttonStyle(RowStyle(selected: selected, cell: true))
            .disabled(total == 0)
            .accessibilityLabel(Text("更早"))
            .accessibilityValue(Text(total, format: .number))
            .accessibilityAddTraits(selected ? .isSelected : [])
        }
        .observing(services.store, id: services.speech, into: $total, onError: workspace.fail) { [moment = services.speech] store in
            try PiSessionList.earlier(PiSessionQuery(limit: 1), at: moment, from: store).total
        }
    }
}

/// 收起的图标条上一格的名字：指针停在格上时浮在格的右边，整窗一层画（`railTips`），不挤排版、不被会话条裁掉；系统的提示要等一秒多，这里一停就出。
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
            .padding(.horizontal, Spacing.group)
            .frame(height: ControlSize.compact.height)
            .paper(cornerRadius: Radius.block, lifted: true)
            .offset(x: frame.maxX + Chrome.groupGap, y: frame.midY - ControlSize.compact.height / 2)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
