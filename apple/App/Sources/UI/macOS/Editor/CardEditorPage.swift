#if os(macOS)
import AppKit
import CueEditor
import CueStore
import SwiftUI

nonisolated private struct EditorData: Sendable, Equatable {
    var card: Card
    var project: Project?
}

/// 打开、收起都是原地淡入淡出，不动几何：前台每帧几何变化会让 AppKit 重算整窗的鼠标跟踪区。
struct CardEditorPage: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: EditorData?
    @State private var editing: CardEditing?
    @State private var mounted = false
    @State private var shown = false
    @State private var settled = false
    @State private var gone = false

    private static let textWidth = InspirationPaper.textWidth
    private static let inset = Spacing.page

    private var isOpen: Bool { workspace.openCard == cardID }

    var body: some View {
        ZStack(alignment: .top) {
            if mounted, let data, let editing {
                editor(data.card, editing)
                    .padding(.top, Spacing.pageTop)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(palette.desk.ignoresSafeArea())
        .opacity(shown ? 1 : 0)
        .allowsHitTesting(shown)
        .debugSettling(isOpen ? !settled : !gone)
        .observing(services.store, id: cardID, into: $data, onError: { [workspace] error in
            if case CueStoreError.notFound = error { return }
            workspace.fail(error)
        }) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return EditorData(card: card, project: try store.project(card.projectID))
        }
        .onChange(of: data?.card.id, initial: true) {
            guard editing == nil, let card = data?.card else { return }
            editing = CardEditing(card, workspace: workspace)
            workspace.openCardEditing = editing
            if isOpen, !mounted { prepare() }
        }
        .onChange(of: data.map { $0.card.isTask || $0.card.parentID != nil }) { _, moved in
            guard moved == true, let card = data?.card else { return }
            workspace.close(.card(cardID))
            workspace.open(card)
        }
        .onChange(of: isOpen) { if !isOpen { collapse() } }
        .overlayHeader(header, in: workspace)
        .task(id: editing?.saveState) {
            guard let editing, editing.saveState == .saved, await SaveState.linger() else { return }
            editing.settleSaved()
        }
        .onDisappear {
            editing?.leave()
            if workspace.openCardEditing === editing { workspace.openCardEditing = nil }
        }
    }

    private func prepare() {
        Task {
            await NextFrame.wait()
            guard isOpen else { return }
            mounted = true
            await NextFrame.wait()
            guard isOpen else { return }
            if editing?.initialText.isEmpty == true { editing?.handle.focus() }
            workspace.presses.opened(cardID)
            withAnimation(Motion.fade) { shown = true } completion: { settled = true }
        }
    }

    private func collapse() {
        withAnimation(Motion.fade) {
            shown = false
        } completion: {
            gone = true
            workspace.finishClosingCard()
        }
    }

    private var header: OverlayHeader.Content {
        OverlayHeader.Content(
            page: .card(cardID), title: data?.project?.shownName ?? "",
            marks: data.map { EditedLine.Marks(edited: $0.card.modifiedAt, pinned: $0.card.isPinned, save: editing?.saveState ?? .idle) },
            failed: editing?.saveState == .failed)
    }

    private func editor(_ card: Card, _ editing: CardEditing) -> some View {
        editing.field(card, theme: .inspiration(palette, horizontalInset: Self.inset, maxTextWidth: Self.textWidth))
    }
}
#endif
