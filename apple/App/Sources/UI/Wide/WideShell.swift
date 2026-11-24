import SwiftUI

/// 宽屏窗口的主体，Mac 的 `MainWindow` 与 iPad 的 `SplitRoot` 共用：会话条、主区的一排（`PaneRow`）、并排的分界、拖放的占位、
/// 会话条放不下时的抽屉与浮在左上的钮（`tools`）、Cue 栏。两端不同的只有栏头让出多少（`inset`）、会话条与浮着的钮长什么样、Cue 栏里放什么。
struct WideShell<Rail: View, Tools: View, Cue: View>: View {
    let focus: WideFocus
    /// 浮层盖着主区时读屏只读浮层（iPad 的页内弹层）。
    var covered = false
    let inset: (_ sizes: WideMetrics, _ index: Int) -> EdgeInsets
    @ViewBuilder let rail: (_ sizes: WideMetrics, _ width: CGFloat) -> Rail
    @ViewBuilder let tools: (WideMetrics) -> Tools
    @ViewBuilder let cue: (_ fits: Bool, _ geometry: GeometryProxy) -> Cue
    @Environment(Workspace.self) private var workspace

    var body: some View {
        GeometryReader { geometry in
            let sizes = WideMetrics(width: geometry.size.width, workspace: workspace)
            HStack(spacing: 0) {
                rail(sizes, sizes.rail)
                Spacer(minLength: 0)
            }
            // 叠在上面的几层按这一排的大小摆；HStack 里的 Spacer 高是 0，侧栏不在时主区会塌成一条线
            .frame(maxHeight: .infinity)
            .overlay { PaneRow(sizes: sizes, window: geometry.size.width, focus: focus) { inset(sizes, $0) } }
            .overlay { if !sizes.fill { ForEach(0..<sizes.widths.count - 1, id: \.self) { BesideDivider(sizes: sizes, index: $0) } } }
            .overlay { WideDropFeedback(window: geometry.size.width) }
            .overlay {
                ZStack(alignment: .topLeading) {
                    if !sizes.fill, !sizes.railFits {
                        RailDrawer(open: workspace.railDrawer, close: { workspace.railDrawer = false }) { rail(sizes, Chrome.rail) }
                    }
                    tools(sizes)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .readerHidden(covered)
            .overlay {
                CueDock(sizes: sizes, width: geometry.size.width, focus: focus) {
                    cue($0, geometry)
                }
            }
            .reportsWideFits(sizes, to: workspace)
        }
    }
}

/// 这一排里的那一页连同它的栏头。页不在这一排时照样挂着、垫在最左那块底下（`PaneRow`）。
struct PageLayer: View {
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.headInset) private var inset
    @Environment(\.underCue) private var under
    @State private var top = PageTop()

    var body: some View {
        let page = workspace.pageRoute
        ZStack(alignment: .top) {
            RouteBody(route: page, column: column)
            if let page, page != .search, workspace.overlay == nil { head(page).padding(.trailing, under) }
        }
        .environment(top)
    }

    @ViewBuilder private func head(_ page: Route) -> some View {
        if page == .progress {
            WideColumnHead(column: column).padding(inset).frame(height: Chrome.band)
        } else {
            WideColumnHead(column: column).padding(inset).frame(height: Chrome.band).windowDragArea()
        }
    }
}

struct SessionLayer: View {
    let route: SessionRoute
    let column: Workspace.Column

    var body: some View { RouteBody(route: .session(route), column: column) }
}

/// 点开盖在页上的那一层：灵感、规则文件。
struct CoverLayer: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.underCue) private var under
    /// 盖着的那条灵感，收起时留到淡完。
    @State private var card: UUID?

    var body: some View {
        ZStack {
            if workspace.isLibraryReady, let card { CardCover(cardID: card) { if workspace.openCard == nil { self.card = nil } }.id(card) }
            LibraryCover()
        }
        .padding(.trailing, under)
        .zIndex(1)
        .onChange(of: workspace.openCard, initial: true) { if let open = workspace.openCard { card = open } }
    }
}

/// 打开、收起都是原地淡入淡出，不动几何：前台每帧几何变化会让 AppKit 重算整窗的鼠标跟踪区。编辑器挂好了才淡入，收起后等淡完才撤（`gone`）。
private struct CardCover: View {
    let cardID: UUID
    let gone: () -> Void
    @Environment(Workspace.self) private var workspace
    @State private var mounted = false
    @State private var shown = false
    @State private var settled = false
    @State private var faded = false

    private var isOpen: Bool { workspace.openCard == cardID }

    var body: some View {
        ZStack {
            if mounted { IdeaPane(cardID: cardID, covers: true, close: { workspace.close(.card(cardID)) }, ready: reveal) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .debugSettling(isOpen ? !settled : !faded)
        .task {
            await NextFrame.wait()
            if isOpen { mounted = true }
        }
        .onChange(of: isOpen) {
            if !isOpen { collapse() } else if mounted { reveal() }
        }
    }

    private func reveal() {
        guard isOpen else { return }
        #if os(macOS)
        workspace.presses.opened(cardID)
        #endif
        withAnimation(Motion.fade) { shown = true } completion: { settled = true }
    }

    private func collapse() {
        withAnimation(Motion.fade) {
            shown = false
        } completion: {
            faded = true
            #if os(macOS)
            workspace.finishClosingCard()
            #endif
            gone()
        }
    }
}

private struct LibraryCover: View {
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            if workspace.isLibraryReady, let file = workspace.openLibraryFile {
                RouteBody(route: .libraryFile(file), column: workspace.pageHost)
                    .overlay(alignment: .top) { LibraryFileHead(file: file) }
                    .id(file).transition(.opacity)
            }
        }
        .animation(Motion.fade, value: workspace.openLibraryFile)
    }
}
