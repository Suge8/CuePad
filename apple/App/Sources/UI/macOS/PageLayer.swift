#if os(macOS)
import CueStore
import SwiftUI

/// 这一排里的那一页连同它的栏头。逛过的页都挂在这里（`PageStack`）：页被别的块换下去时只是藏起，回来不用重排。
struct PageLayer: View {
    let column: Workspace.Column
    @Environment(Workspace.self) private var workspace
    @Environment(\.headInset) private var inset
    @Environment(\.underCue) private var under

    var body: some View {
        ZStack(alignment: .top) {
            PageStack().overlay(alignment: .bottom) { SelectionSlot().padding(.trailing, under) }
            if let page = workspace.pageRoute, workspace.overlay == nil { head(page).padding(.trailing, under) }
        }
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
    @Environment(\.underCue) private var under

    var body: some View {
        if route.sessionID != nil { SessionPage(route, column: column).padding(.trailing, under) }
    }
}

/// 点开盖在页上的那一层：灵感、规则文件。
struct CoverLayer: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.underCue) private var under

    var body: some View {
        Group {
            if workspace.isLibraryReady, let id = workspace.presses.presented { CardCover(cardID: id).id(id) }
            LibraryFileLayer()
        }
        .padding(.trailing, under)
        .zIndex(1)
    }
}

/// 打开、收起都是原地淡入淡出，不动几何：前台每帧几何变化会让 AppKit 重算整窗的鼠标跟踪区。
/// 收起后还挂着，等淡完才撤（`Workspace.finishClosingCard`）。
private struct CardCover: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @State private var mounted = false
    @State private var shown = false
    @State private var settled = false
    @State private var gone = false

    private var isOpen: Bool { workspace.openCard == cardID }

    var body: some View {
        ZStack {
            if mounted { IdeaPane(cardID: cardID, covers: true, close: { workspace.close(.card(cardID)) }, ready: reveal) }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .debugSettling(isOpen ? !settled : !gone)
        .task {
            await NextFrame.wait()
            if isOpen { mounted = true }
        }
        .onChange(of: isOpen) { if !isOpen { collapse() } }
    }

    private func reveal() {
        guard isOpen else { return }
        workspace.presses.opened(cardID)
        withAnimation(Motion.fade) { shown = true } completion: { settled = true }
    }

    private func collapse() {
        withAnimation(Motion.fade) {
            shown = false
        } completion: {
            gone = true
            workspace.finishClosingCard()
        }
    }
}
#endif
