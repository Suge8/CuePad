import CueStore
import SwiftUI

/// 宽屏左栏（会话条）：导航只在这一处。从上到下是去处（项目、进展、更早，选中是"主区此刻放的就是它"）、等你与推进中（`SessionRail`）、
/// Mac 最底下一行（技能与规则、设置、额度）；iPad 顶上另有一组钮（侧栏钮、搜索、Cue 钮）。尺寸全在 `Chrome`。
/// 只有开着、藏起两态（`Chrome` 头注释）：藏起时排版上宽 0；视图树一直挂着（滚动位置、读到的数都在），不放循环动效、点不到、读屏跳过，放回来不重建。
/// Mac 上藏起时它照原宽画在主区下面（主区铺满桌面色、盖住它）：开合时看得见的只有主区从它上面滑过（`WideColumnView.move`），它自己不动、不换样子；iPad 裁成 0 宽。
/// 藏起后注意力不丢：开合钮角上一颗点说有没有在等你（`SidebarToggle`），Cue 的名牌写着数字账，看板也在。
/// 每一行是系统侧栏那种带字的行（`RailLine`），行首图标那一列正对红绿灯的左沿（`Chrome.lead`）。面怎么画在 `RailSurface`。
/// Mac 的开合钮在窗口最顶那一排、红绿灯右边（`SidebarToggle`），开着藏起都不动；搜索是这一页的操作，在主区栏头右端（`SearchSlot`）。
/// 宽 `Chrome.rail`，不能拖：它是每个自动藏起临界宽的一项（`WideMetrics`），拖宽要么逐帧挪三栏（违背 Mac 开合不逐帧挪位置），要么只拖一条线、松手才变，换来的只是二十来点。
/// 被否决的：开合钮与搜索放在会话条顶上一行（占一整行，搜索与会话条无关）；开合钮做成玻璃圆钮（圆底压在会话条与主区的分界上）。
struct WideRail: View {
    /// 此刻的宽：`Chrome.rail` 或藏起的 0。
    let width: CGFloat
    #if os(iOS)
    /// iPad 的 Cue 钮在顶上那一组（`CueButton`）；Mac 的在窗口右上、只在 Cue 收着时有。
    var cue: (fits: Bool, shown: Bool)?
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    private var shown: Bool { width > 0 }

    var body: some View {
        RailSurfaceView(surface: RailSurface.current) { rows }
            .frame(width: Chrome.rail)
            .environment(\.pageActive, shown)
            .frame(width: width, alignment: .leading)
            #if os(iOS)
            .clipped()
            #endif
            .allowsHitTesting(shown)
            .readerHidden(!shown)
    }

    private var rows: some View {
        VStack(spacing: Chrome.groupGap) {
            #if os(iOS)
            RailGroup {
                RailIcon(icon: .sidebar, help: "显示或隐藏侧栏（⌃⌘S）") { workspace.toggleSidebar() }
                RailIcon(icon: .search, help: "搜索") { workspace.openSearch() }
                if let cue { CueButton(fits: cue.fits, shown: cue.shown).frame(width: Chrome.control, height: Chrome.control) }
            }
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

/// 会话条的面：两种画法的原型对比（`-CuePadRailV4 a|b`，`DebugHooks.railSurface`），定下后只留一种。
/// - `floating`（a）：浮起的一块（macOS 26 的侧栏：WWDC25「Build an AppKit app with the new design」"sidebars appear as a pane of glass that floats above the window's content"）。
///   离窗口上、左、下与主区各一档（`Chrome.float`），圆角与窗口同心（`Radius.card`），红绿灯坐在它里面；一层发丝描边与最轻的投影，读作浮在桌面上。
///   不用 Liquid Glass 的材质：它背后只有一片平的桌面色，玻璃折射不出东西，只剩一层发灰的着色。
/// - `flush`（b）：贴边的实底：会话条的底色从窗口顶一直铺到底，红绿灯与开合钮坐在会话条的底色上（Things 3、Linear 的做法），与主区靠底色分开、不画分割线。
enum RailSurface {
    case floating, flush

    static let current = DebugHooks.railSurface ?? .floating

    /// 会话条那一块离会话条外框多少（浮起的一块四周让出一档；贴边的不让）。
    var inset: CGFloat { self == .floating ? Chrome.float : 0 }
    /// 那一块的圆角（贴边的直角，窗口自己的圆角裁它）。
    var radius: CGFloat { self == .floating ? Radius.card : 0 }
}

/// 会话条那一块：底、圆角、描边与里面行的排法。里面的行左右离那一块的边让到 `Chrome.gutter`（两种面行首都对着红绿灯）；
/// Mac 上第一组从最顶那一排下面开始（那一排是红绿灯与开合钮）。
private struct RailSurfaceView<Content: View>: View {
    let surface: RailSurface
    @ViewBuilder let content: Content
    @Environment(\.palette) private var palette

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: surface.radius, style: .continuous)
        content
            #if os(macOS)
            .padding(.top, Chrome.band - surface.inset)
            .padding(.bottom, Chrome.float - surface.inset)
            #endif
            .padding(.horizontal, Chrome.gutter - surface.inset)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .rowContainer(shape)
            .environment(\.rowSurface, palette.sidebar)
            .background {
                shape.fill(palette.sidebar)
                    .overlay { if surface == .floating { shape.strokeBorder(palette.hair) } }
                    .elevation(surface == .floating && !palette.dark ? .hover : nil)
            }
            .padding(surface.inset)
    }
}

#if os(macOS)
/// 会话条的开合钮（⌃⌘S）：窗口最顶那一排、红绿灯右边一颗无底的图标钮（`ControlButtonStyle.icon`，圆与红绿灯一个分量：`ControlSize.compact`），
/// 悬停才浮淡底，同系统工具栏不带玻璃的项。会话条开着、藏起都不动（`Chrome.toggle`，同访达、备忘录）。
/// 会话条藏起时角上一颗点说有没有在等你：有要拍板的是赭黄，只有待回复的是墨色（数只读 `CueNow.Tally`，同 Cue 的名牌与 App 图标的角标，不另算）；开着时等你那一组就在眼前，不画。
struct SidebarToggle: View {
    let railShown: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let tally = workspace.cue.now.tally
        let dot: Color? = railShown ? nil : tally.asks > 0 ? palette.waiting : tally.reply > 0 ? palette.ink : nil
        Button("显示或隐藏侧栏", icon: .sidebar) { workspace.toggleSidebar() }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .icon, size: .compact))
            .overlay(alignment: .topTrailing) {
                if let dot { StatusDot(color: dot, rim: palette.desk).offset(x: Self.dotShift, y: -Self.dotShift).transition(Motion.pop(reduceMotion: reduceMotion)) }
            }
            .animation(Motion.fade, value: dot)
            .help(Text("显示或隐藏侧栏（⌃⌘S）"))
            .accessibilityValue(dot == nil ? Text("") : Text("等你 \(tally.needsYou)"))
            .padding(.leading, Chrome.toggle)
            .frame(height: Chrome.band)
    }

    /// 点压在圆的右上角外沿上（圆心约在圆框的内切点）。
    private static let dotShift: CGFloat = Spacing.hair
}

/// 搜索（⌘K）：主区栏头右端、"⋯"左边的一颗玻璃圆钮（Mac 的惯例：工具栏右端是这一页的操作与搜索）。
/// 浏览页与辅助页的栏头（`MainColumn`）、看板那一排、会话栏头（`WideSessionTitle`）都有；并排两个会话时只在左半的栏头上，一个窗口只一颗。
struct SearchSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("搜索", icon: .search) { workspace.searching.toggle() }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .help("搜索（⌘K）")
            .disabled(!workspace.isLibraryReady)
    }

    /// 栏头右端让给它的宽：钮前那道缝与圆钮。
    static let reserve = Spacing.item + ControlMetrics.height
}

/// 会话条最底下的图标钮（技能与规则、设置）：同开合钮一种无底、悬停才浮一圈淡底的钮（`PressStyle(.button)`，圆同红绿灯一个分量），
/// 图标同会话条上别的行首图标（`Glyph.control`、次一档的墨）：放在会话条里的都是会话条的一员，不比行首图标重。
private struct RailTool: View {
    let icon: Icon
    let help: LocalizedStringResource
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            Image(icon).font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: ControlSize.compact.height, height: ControlSize.compact.height)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .help(Text(help))
        .accessibilityLabel(Text(help))
    }
}
#endif

/// 会话条上的一组行（去处、iPad 顶上那几颗钮）：行与行之间一道缝（`Spacing.hair`，同各组的会话），行的框让出行底向两边伸出的那一截。
struct RailGroup<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) { content }
            .padding(.horizontal, RowMetrics.bleed)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 会话条上的一行：行首图标那一列（`Chrome.icon` 宽：图标或状态标），右边隔一档是名字与读数（`rest`）。
struct RailLine<Lead: View, Rest: View>: View {
    /// 等你组的会话高一档（`Chrome.tallRow`）。
    var height = Chrome.row
    @ViewBuilder let lead: Lead
    @ViewBuilder let rest: Rest

    var body: some View {
        HStack(spacing: Spacing.item) {
            lead.frame(width: Chrome.icon)
            HStack(spacing: Spacing.glyph) { rest }
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: height)
        .contentShape(.rect)
    }
}

/// 项目、进展：图标与名字的一行。
private struct RailRow: View {
    let title: LocalizedStringResource
    let icon: Icon
    let selected: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            RailLine {
                Image(icon).font(Glyph.control).foregroundStyle(selected ? palette.ink : palette.ink2)
            } rest: {
                Text(title).font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .accessibilityLabel(Text(title))
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

#if os(iOS)
/// iPad 会话条顶上的图标钮：一格（`Chrome.control` 见方），悬停、按下是这一格的淡底。
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
#endif

/// 会话条上的"更早"：已结束的会话（`PiSessionList.earlier`，正在唤醒的在推进中；已结束的只在这里与搜索），排在去处一组的进展下面、同一种行，写个数。
/// 点它在主区打开"更早"那一页（`Route.earlier`，`EarlierPage`，三端同一页）；个数与那一页读同一个查询，两边对得上。没有已结束的会话时置灰。
struct RailEarlier: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var total: Int?

    var body: some View {
        let total = total ?? 0
        let selected = workspace.mainRoute == .earlier
        Button { workspace.show(.earlier) } label: {
            RailLine {
                Image(.session).font(Glyph.control).foregroundStyle(selected ? palette.ink : palette.ink2)
            } rest: {
                Text("更早").font(Typography.body.weight(selected ? .semibold : .regular)).foregroundStyle(palette.ink).lineLimit(1)
                Spacer(minLength: 0)
                Text(total, format: .number).font(Typography.caption).foregroundStyle(palette.ink3).monospacedDigit()
            }
        }
        .buttonStyle(RowStyle(selected: selected))
        .disabled(total == 0)
        .accessibilityLabel(Text("更早"))
        .accessibilityValue(Text(total, format: .number))
        .accessibilityAddTraits(selected ? .isSelected : [])
        .observing(services.store, id: services.speech, into: $total, onError: workspace.fail) { [moment = services.speech] store in
            try PiSessionList.earlier(PiSessionQuery(limit: 1), at: moment, from: store).total
        }
    }
}

