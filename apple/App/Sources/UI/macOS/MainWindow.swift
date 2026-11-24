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
        WideShell(focus: focus) { sizes, index in
            let leading = index == 0 ? Chrome.headLead(rail: sizes.rail) : sizes.fill ? Chrome.toggle : Spacing.page
            let besideCue = index == sizes.widths.count - 1 || index > 0 && sizes.fill
            let trailing = besideCue && sizes.cue == 0 ? CueButton.reserve : Spacing.page
            return EdgeInsets(top: 0, leading: leading, bottom: 0, trailing: trailing)
        } rail: { _, width in
            WideRail(width: width)
        } tools: { sizes in
            if !sizes.fill { SidebarToggle(sizes: sizes) }
            if !workspace.cueShown(sizes) {
                CueButton(fits: sizes.cueFits).padding(.trailing, Spacing.page).frame(height: Chrome.band).frame(maxWidth: .infinity, alignment: .trailing)
            }
        } cue: { fits, _ in
            CueColumn(fits: fits)
        }
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
