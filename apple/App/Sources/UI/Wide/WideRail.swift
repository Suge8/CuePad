import CueStore
import SwiftUI

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
            RailHome()
            RailSessions(data: services.liveSessions.rail, marked: Set(workspace.shownSessions.compactMap(\.sessionID))) { session, opening in
                workspace.openSession(session.id, sessionID: session.sessionID, in: opening == .beside ? .aside : .main)
            }
            tools
        }
    }

    private var tools: some View {
        HStack(spacing: Spacing.tight) {
            #if os(macOS)
            RailTool(icon: .search, help: "搜索（⌘K）") { workspace.searching.toggle() }.disabled(!workspace.isLibraryReady)
            RailTool(icon: .instruction, help: "技能与规则") { workspace.show(.library) }
            RailTool(icon: .settings, help: "设置（⌘,）") { SettingsPane.open() }
            #else
            RailTool(icon: .search, help: "搜索") { workspace.openSearch() }
            RailTool(icon: .instruction, help: "技能与规则") { workspace.push(.library) }
            RailTool(icon: .settings, help: "设置") { workspace.push(.settings) }
            RemoteMacButton().railTool()
            #endif
            Spacer(minLength: 0)
            RailQuota()
        }
        .padding(.leading, RailTool.lead)
        .padding(.trailing, RowMetrics.bleed)
        .frame(height: Chrome.control)
        .floatingAbove { NoticeSlot(place: .rail) }
    }
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
            if floating { CueButton(fits: sizes.cueFits, shown: workspace.cueShown(sizes)).frame(width: Chrome.control, height: Chrome.control) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.leading, floating ? Chrome.lead : RailTool.lead)
    }

    @ViewBuilder private func tool(_ icon: Icon, _ help: LocalizedStringResource, action: @escaping () -> Void) -> some View {
        if floating {
            Button(help, icon: icon, action: action)
                .labelStyle(.iconOnly)
                .buttonStyle(ControlButtonStyle(kind: .circular))
        } else {
            RailTool(icon: icon, help: help, action: action)
        }
    }
}

#endif

private struct RailQuota: View {
    @Environment(AppServices.self) private var services
    @State private var detail = BubbleSwitch(open: DebugHooks.preset.quotaOpen)

    var body: some View {
        QuotaRings(open: detail.open, height: Chrome.control, cell: true) { detail.toggle() }
            .bubble($detail, width: QuotaDetail.bubbleWidth(accounts: services.accountQuotas.items.count)) { QuotaDetail().padding(QuotaDetail.bubblePadding) }
            .refreshesQuota(open: detail.open)
    }
}
