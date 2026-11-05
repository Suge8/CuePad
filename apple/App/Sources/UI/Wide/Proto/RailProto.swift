import CueStore
import SwiftUI

/// 会话条重设计原型（`-CuePadRailProto A`，只在 Debug 读，`DebugHooks.railProto`）：挑定的方向（A 平铺克制，等你组借 C 写它要什么），
/// 挑定后按正式标准重写进 `WideRail` 与 `SessionRail`，原型不进主分支。
/// - 红绿灯那一排不归会话条：开合钮与搜索是那一排的两颗玻璃圆钮，钉在红绿灯右边、两种宽下不动（`WindowBandTools`，Mac）；
/// - 去处一组：项目、进展、更早，紧接在那一排下面；
/// - 会话：不铺纸，组靠组头与间距分开（`RailProtoSessions`）；
/// - Mac 最底下一行：技能与规则、设置两格并排在中轴上，展开时额度靠右、右沿同行尾读数。
/// 所有格在收起与展开两种宽下 x、y 不动，展开只露出右边的字（`ProtoLine`，字随 `Motion.fade` 淡入）。
struct RailProto: View {
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
            #if os(iOS)
            RailGroup {
                RailIcon(icon: .sidebar, help: "显示或隐藏侧栏（⌃⌘S）") { workspace.toggleSidebar() }
                RailIcon(icon: .search, help: "搜索") { workspace.openSearch() }
                if let cue { CueButton(fits: cue.fits, shown: cue.shown).frame(width: Chrome.control, height: Chrome.control) }
            }
            #endif
            ProtoRows {
                ProtoPlace(title: "项目", icon: .folder, selected: workspace.shownPane == .projects, wide: wide) { workspace.selectPane(.projects) }
                ProtoPlace(title: "进展", icon: .task, selected: workspace.shownPane == .progress, wide: wide) { workspace.selectPane(.progress) }
                ProtoEarlier(wide: wide)
            }
            RailProtoSessions(rows: SessionRailRows(services.liveSessions.rail, pulse: workspace.pulse), wide: wide,
                              marked: Set(workspace.shownSessions.compactMap(\.sessionID)))
            #if os(macOS)
            tools
            #endif
        }
        #if os(macOS)
        .padding(.top, Chrome.railTop)
        #endif
        .frame(width: width)
        .background(palette.sidebar)
    }

    #if os(macOS)
    private var tools: some View {
        HStack(spacing: Chrome.cellGap) {
            RailIcon(icon: .instruction, help: "技能与规则") { workspace.show(.library) }
            RailIcon(icon: .settings, help: "设置（⌘,）") { SettingsPane.open() }
            Spacer(minLength: 0)
            // 额度的右沿同行尾读数那一列（组的右沿、行底的内边）；收起时没有它，两格正在中轴上
            if wide { SidebarQuota().padding(.trailing, Chrome.edge + Chrome.pad - Chrome.pairEdge) }
        }
        .padding(.horizontal, Chrome.pairEdge)
        .padding(.bottom, Chrome.pad)
    }
    #endif
}

/// 会话条上的一组行（去处、各组的会话）：左沿在 `Chrome.edge`，行与行之间一道缝（`Spacing.hair`），整条栏一种节奏。
struct ProtoRows<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.hair) { content }
            .padding(.horizontal, Chrome.pad)
            .frame(maxWidth: .infinity, alignment: .leading)
            .rowContainer(.rect(cornerRadius: Radius.block))
            .padding(.horizontal, Chrome.edge)
    }
}

/// 原型里的一行：行首一格（`Chrome.control` 宽、`height` 高）在中轴上，右边的字叠在行上、收起时淡去（`Motion.fade`），格一点不挪。
struct ProtoLine<Lead: View, Rest: View>: View {
    let wide: Bool
    var height = Chrome.control
    @ViewBuilder let lead: Lead
    @ViewBuilder let rest: Rest

    var body: some View {
        lead.frame(width: Chrome.control, height: height)
            .frame(maxWidth: .infinity, minHeight: height, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: Spacing.glyph) { rest }
                    .padding(.leading, Chrome.control)
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
/// 窗口最顶那一排左端的两颗玻璃圆钮：开合会话条（⌃⌘S）、搜索（⌘K）。钉在红绿灯右边（`Chrome.bandTools`），会话条展开、收起都不动，
/// 收起时伸进主区栏头那一段，主区栏头的左边让出它们（`MainWindow` 给 `headInset`）。
/// 搜索放这里而不是主区栏头右端：搜的是整个库（灵感、任务、会话），不属于哪一页；一处固定的位置，会话条展开（默认）时不占主区栏头一点宽。
struct WindowBandTools: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        HStack(spacing: Spacing.item) {
            Button("显示或隐藏侧栏", icon: .sidebar) { workspace.toggleSidebar() }
                .help("显示或隐藏侧栏（⌃⌘S）")
            Button("搜索", icon: .search) { workspace.searching.toggle() }
                .help("搜索（⌘K）")
                .disabled(!workspace.isLibraryReady)
        }
        .labelStyle(.iconOnly)
        .buttonStyle(ControlButtonStyle(kind: .circular))
        .padding(.leading, Chrome.bandTools)
        .frame(height: Chrome.band)
    }
}
#endif
