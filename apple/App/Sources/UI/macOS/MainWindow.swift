#if os(macOS)
import CueStore
import SwiftUI

struct MainWindow: View {
    @State var workspace: Workspace
    @Environment(\.palette) private var palette

    @State private var focus = WideFocus()

    var body: some View {
        CatalogGate { columns }
        .ignoresSafeArea(.container, edges: .top)
        .previewPresenter(Bindable(workspace).preview, reply: nil)
        .background(palette.desk)
        .background { WindowPanels(workspace: workspace) }
        .background { TaskBubbleSlot() }
        .background { WorkspaceShortcuts(workspace: workspace) }
        .background { CardPressMonitor(workspace: workspace) }
        .overlay { Prewarm().environment(workspace) }
        .overlay { NoticeView() }
        .followsUndo(workspace)
        .toolbar(removing: .title)
        .toolbarBackgroundVisibility(.hidden, for: .windowToolbar)
        .panelHost()
        .environment(workspace)
    }

    private var columns: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            let trail = sizes.cue == 0 ? CueButton.reserve : Spacing.page
            let under = sizes.split ? 0 : sizes.cue
            HStack(spacing: 0) {
                WideRail(width: sizes.rail)
                WideColumnHost(slot: .main, focus: focus, origin: sizes.rail, width: sizes.leading + under, shape: sizes.shape, hidden: sizes.fill, under: under, spans: sizes.spans) {
                    MainColumn().environment(\.headInset, Self.inset(leading: Chrome.headLead(rail: sizes.rail), trailing: sizes.split ? Spacing.page : trail))
                        .environment(\.pageActive, !sizes.fill)
                        .environment(\.underCue, under)
                }
                .frame(width: sizes.leading + under)
                Spacer(minLength: 0)
            }
            .overlay(alignment: .topLeading) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<WideNavigation.maxPanes - 1, id: \.self) { beside($0, sizes, window: geometry.size.width, trail: trail) }
                }
            }
            .overlay { if !sizes.fill { ForEach(0..<sizes.widths.count - 1, id: \.self) { BesideDivider(sizes: sizes, index: $0) } } }
            .overlay { WideDropFeedback(window: geometry.size.width) }
            .overlay { if !sizes.fill { railChrome(sizes) } }
            .reportsWideFits(sizes, to: workspace)
            .overlay(alignment: .topTrailing) {
                if !workspace.cueShown(sizes) { CueButton(fits: sizes.cueFits).padding(.trailing, Spacing.page).frame(height: Chrome.band) }
            }
            .overlay { CueDock(sizes: sizes, width: geometry.size.width, focus: focus) { CueColumn(fits: $0) } }
        }
    }

    private func beside(_ index: Int, _ sizes: WideMetrics, window: CGFloat, trail: CGFloat) -> some View {
        let origin = sizes.origin(index + 1, window: window), width = sizes.width(index + 1)
        let last = index + 2 == sizes.widths.count
        return WideColumnHost(slot: .beside(index), focus: focus, origin: origin, width: width, shape: sizes.shape, hidden: origin >= window, spans: sizes.spans) {
            BesideColumn(index: index) { SessionPage($0, column: .beside(index)) } card: { IdeaPane(cardID: $0, column: .beside(index)) }
                .environment(\.headInset, Self.inset(leading: sizes.fill ? Chrome.toggle : Spacing.page, trailing: last || sizes.fill ? trail : Spacing.page))
        }
        .frame(width: width)
        .padding(.leading, origin)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func railChrome(_ sizes: WideMetrics) -> some View {
        ZStack(alignment: .topLeading) {
            if !sizes.railFits { RailDrawer(open: workspace.railDrawer, close: { workspace.railDrawer = false }) { WideRail(width: Chrome.rail) } }
            SidebarToggle(sizes: sizes)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private static func inset(leading: CGFloat = Spacing.page, trailing: CGFloat) -> EdgeInsets {
        EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
    }
}

/// 本窗口的浮层与确认框（都经 `panel`）。单独一个视图读它们的开合：主窗口的视图体读了，开合的那一帧就要重算整个窗口、重新提交整条工具栏。
private struct WindowPanels: View {
    @Bindable var workspace: Workspace
    @State private var mountsPalette = false

    var body: some View {
        Color.clear.frame(width: 0, height: 0)
            .keptPanel(isPresented: $workspace.searching, mounted: mountsPalette) { SearchPalette() }
            .onChange(of: workspace.searching) { if $1 { mountsPalette = true } }
            .task(id: workspace.isLibraryReady) {
                guard workspace.isLibraryReady else { return }
                guard (try? await Task.sleep(for: Prewarm.delay)) != nil else { return }
                mountsPalette = true
            }
            .panel(item: $workspace.projectForm) { ProjectForm($0) }
            .modifier(NewInputPanel())
            .panel(isPresented: $workspace.showsSetup) { SetupPanel() }
            .sessionAsks(workspace)
    }
}

struct EditorLayer: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.isLibraryReady, let id = workspace.presses.presented {
            CardEditorPage(cardID: id).id(id)
        }
    }
}

struct SelectionSlot: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        if workspace.isLibraryReady, workspace.overlay == nil, workspace.presses.presented == nil, workspace.presses.isSelecting {
            SelectionBar().padding(.bottom, Spacing.block).transition(.opacity)
        }
    }
}

private struct WorkspaceShortcuts: View {
    let workspace: Workspace

    var body: some View {
        ZStack {
            ForEach(Array(1...9).prefix(workspace.catalog?.projects.count ?? 0), id: \.self) { number in
                Button("项目 \(number)") { workspace.showProject(number: number) }
                    .keyboardShortcut(KeyEquivalent(Character("\(number)")))
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

}
#endif
