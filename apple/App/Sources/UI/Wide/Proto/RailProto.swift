import CueStore
import SwiftUI

/// 会话条重设计原型（`-CuePadRailProto A|B|C`，只在 Debug 读，`DebugHooks.railLook`）：同一套排法下的三个方向，挑定后按正式标准重写进
/// `WideRail` 与 `SessionRail`，原型不进主分支。三个方向共用骨架，只有会话那一段（与 B 顶上的搜索）各画各的：
/// - 红绿灯那一排两种宽都空着；顶上一行两格并排（侧栏钮、搜索），收起时两格连同中缝正在中轴上，比现状少占一整行；
/// - 去处一组：项目、进展、更早（更早是一页，与另两个同类，不再漂在底部）；
/// - 会话：不铺纸，会话条是一整块实底，组靠间距与组头分开（`RailProtoA`、`B`、`C`）；
/// - Mac 最底下一行：技能与规则、设置两格并排，展开时额度靠右，钮与读数分在两头。
/// 所有格在收起与展开两种宽下 x、y 不动，展开只露出右边的字（`ProtoLine`，字随 `Motion.fade` 淡入）。
struct RailProto: View {
    let look: DebugHooks.RailLook
    let width: CGFloat
    #if os(iOS)
    var cue: (fits: Bool, shown: Bool)?
    #endif
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette

    private var wide: Bool { width == Chrome.rail }

    var body: some View {
        VStack(spacing: Chrome.groupGap) {
            #if os(macOS)
            Color.clear.frame(height: Chrome.band - Chrome.groupGap)
            #endif
            top
            RailGroup {
                ProtoPlace(title: "项目", icon: .folder, selected: workspace.shownPane == .projects, wide: wide) { workspace.selectPane(.projects) }
                ProtoPlace(title: "进展", icon: .task, selected: workspace.shownPane == .progress, wide: wide) { workspace.selectPane(.progress) }
                ProtoEarlier(wide: wide)
            }
            sessions
            #if os(macOS)
            tools
            #endif
        }
        .frame(width: width)
        .background(palette.sidebar)
        .environment(\.protoInset, look == .b ? Spacing.tight : 0)
    }

    @ViewBuilder private var sessions: some View {
        let rows = SessionRailRows(services.liveSessions.rail, pulse: workspace.pulse)
        let marked = Set(workspace.shownSessions.compactMap(\.sessionID))
        switch look {
        case .a: RailProtoA(rows: rows, wide: wide, marked: marked)
        case .b: RailProtoB(rows: rows, wide: wide, marked: marked)
        case .c: RailProtoC(rows: rows, wide: wide, marked: marked)
        }
    }

    #if os(macOS)
    private var top: some View {
        HStack(spacing: Chrome.cellGap) {
            RailIcon(icon: .sidebar, help: "显示或隐藏侧栏（⌃⌘S）") { workspace.toggleSidebar() }
            Group {
                if look == .b {
                    ProtoSearchField(wide: wide) { workspace.searching.toggle() }
                } else {
                    RailIcon(icon: .search, help: "搜索（⌘K）") { workspace.searching.toggle() }
                    Spacer(minLength: 0)
                }
            }
            .disabled(!workspace.isLibraryReady)
        }
        .padding(.horizontal, Chrome.pairEdge)
    }

    private var tools: some View {
        HStack(spacing: Chrome.cellGap) {
            RailIcon(icon: .instruction, help: "技能与规则") { workspace.show(.library) }
            RailIcon(icon: .settings, help: "设置（⌘,）") { SettingsPane.open() }
            Spacer(minLength: 0)
            if wide { SidebarQuota() }
        }
        .padding(.horizontal, Chrome.pairEdge)
        .padding(.bottom, Chrome.pad)
    }
    #else
    /// iPad 的图标条只放得下一格（`Chrome.strip` 80），顶上那几颗照现状竖排。
    private var top: some View {
        RailGroup {
            RailIcon(icon: .sidebar, help: "显示或隐藏侧栏（⌃⌘S）") { workspace.toggleSidebar() }
            RailIcon(icon: .search, help: "搜索") { workspace.openSearch() }
            if let cue { CueButton(fits: cue.fits, shown: cue.shown).frame(width: Chrome.control, height: Chrome.control) }
        }
    }
    #endif
}

extension EnvironmentValues {
    /// 字离行首那一格多远：B 的头像几乎占满一格，字往右让一档，整条会话条的字仍是同一条左边。
    @Entry var protoInset: CGFloat = 0
}

/// 原型里的一行：行首一格（`Chrome.control` 宽、`height` 高）在中轴上，右边的字叠在行上、收起时淡去（`Motion.fade`），格一点不挪。
struct ProtoLine<Lead: View, Rest: View>: View {
    let wide: Bool
    var height = Chrome.control
    @ViewBuilder let lead: Lead
    @ViewBuilder let rest: Rest
    @Environment(\.protoInset) private var inset

    var body: some View {
        lead.frame(width: Chrome.control, height: height)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: Spacing.glyph) { rest }
                    .padding(.leading, Chrome.control + inset)
                    .padding(.trailing, Spacing.item)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .opacity(wide ? 1 : 0)
                    .animation(Motion.fade, value: wide)
            }
            .clipped()
            .contentShape(.rect)
    }
}

/// 去处：项目、进展（选中是主区此刻放的就是它）。
private struct ProtoPlace: View {
    let title: LocalizedStringResource
    let icon: Icon
    let selected: Bool
    let wide: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) {
            ProtoLine(wide: wide) {
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

/// 更早：已结束的会话那一页，排进去处一组、写个数（同 `RailEarlier` 读同一个查询）。
private struct ProtoEarlier: View {
    let wide: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var total: Int?

    var body: some View {
        let total = total ?? 0
        let selected = workspace.mainRoute == .earlier
        Button { workspace.show(.earlier) } label: {
            ProtoLine(wide: wide) {
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
        .observing(services.store, id: services.speech, into: $total, onError: workspace.fail) { [moment = services.speech] store in
            try PiSessionList.earlier(PiSessionQuery(limit: 1), at: moment, from: store).total
        }
    }
}

#if os(macOS)
/// B 顶上的搜索：收起时是一格放大镜，展开时同一格往右长成一条纸色的搜索框（放大镜不挪，"搜索"与 ⌘K 露出来）。
private struct ProtoSearchField: View {
    let wide: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    var body: some View {
        Button(action: action) { label }
            .buttonStyle(PressStyle(.card))
            .help(Text("搜索（⌘K）"))
            .accessibilityLabel(Text("搜索"))
    }

    private var label: some View {
        HStack(spacing: 0) {
            Image(.search).font(Glyph.control).foregroundStyle(palette.ink2)
                .frame(width: Chrome.control, height: Chrome.control)
            field.opacity(wide ? 1 : 0)
        }
        .frame(maxWidth: .infinity, maxHeight: Chrome.control)
        .background { Capsule().fill(palette.paper).opacity(wide ? 1 : 0) }
        .clipped()
        .contentShape(.rect)
        .animation(Motion.fade, value: wide)
    }

    @ViewBuilder private var field: some View {
        Text("搜索").font(Typography.body).foregroundStyle(palette.ink3)
        Spacer(minLength: 0)
        Text(verbatim: "⌘K").font(Typography.keycap).foregroundStyle(palette.ink3).padding(.trailing, Spacing.group)
    }
}
#endif
