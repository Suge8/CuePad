import CueEditor
import CueStore
import SwiftUI

/// 宽屏上的一条灵感，只此一份：并排的一块、点开盖在页上的那一层（Mac 的 `CardCover`、iPad 的 `PaneColumn`）都是它。
/// 盖着时（`covers`）它还不是这一排里的一块：收起是合上这一层，胶囊旁多一颗钮把它放到旁边并排。
struct IdeaPane: View {
    let cardID: UUID
    var covers = false
    let close: () -> Void
    /// 编辑器挂上后的下一帧报一次：盖上来的那一层等它再淡入。
    var ready: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var data: Shown?
    @State private var editing: CardEditing?
    @State private var sharing = InspirationSharing()

    nonisolated private struct Shown: Sendable, Equatable {
        var card: Card
        var project: Project?
    }

    var body: some View {
        ZStack(alignment: .top) {
            if let data, let editing {
                editor(data.card, editing).padding(.top, Chrome.band + Spacing.item)
            }
            head
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
        .modifier(InspirationSharePresentation(sharing: sharing, editing: editing))
        .observing(services.store, id: cardID, into: $data, onError: { [workspace] error in
            if case CueStoreError.notFound = error { return }
            workspace.fail(error)
        }) { [cardID] store in
            guard let card = try store.card(cardID) else { throw CueStoreError.notFound }
            return Shown(card: card, project: try store.project(card.projectID))
        }
        .onChange(of: data?.card.id, initial: true) {
            guard editing == nil, let card = data?.card else { return }
            let editing = CardEditing(card, workspace: workspace)
            self.editing = editing
            Task {
                await NextFrame.wait()
                if covers, editing.initialText.isEmpty { editing.handle.focus() }
                ready?()
            }
        }
        .onChange(of: data.map { $0.card.isTask || $0.card.parentID != nil }) { _, moved in
            guard moved == true, let card = data?.card else { return }
            close()
            workspace.open(card)
        }
        .onDisappear { editing?.leave() }
    }

    @ViewBuilder private func editor(_ card: Card, _ editing: CardEditing) -> some View {
        let theme = CueEditorTheme.inspiration(palette, horizontalInset: Spacing.page, maxTextWidth: InspirationPaper.textWidth)
        #if os(macOS)
        editing.field(card, theme: theme)
        #else
        CardTextField(card: card, editing: editing, theme: theme)
        #endif
    }

    private var head: some View {
        PaneHead {
            PaneTitle(crumb: .init(data?.project, in: workspace), title: editing?.title ?? "", handle: .card(cardID), close: close) {
                if let card = data?.card, let editing { InspirationEditorActions(card: card, editing: editing, sharing: sharing) }
            } tools: {
                if covers { BesideTool(cardID: cardID) }
            }
        }
    }
}

/// 把盖着的这条灵感放到底下那一块的右边并排：底下是会话就是边聊边看。也可以直接拖它的胶囊。
private struct BesideTool: View {
    let cardID: UUID
    @Environment(Workspace.self) private var workspace

    var body: some View {
        let under = workspace.pane(in: workspace.pageHost)
        if under?.standsAlone == false {
            HeadTool(label: under?.session == nil ? "并排打开" : "边聊边看", icon: .rightColumn) {
                let fits = workspace.wideShown < workspace.wideRoom
                if !fits || !workspace.drop(.card(cardID), at: workspace.pageHost.index + 1, replacing: false) { workspace.say("窗口太窄，放不下并排", tone: .failure) }
            }
        }
    }
}

#if os(iOS)
/// 手机上的边聊边看：挑一个会话，灵感停在它的回复框上方。
struct ChatAlongsideButton: View {
    let cardID: UUID
    var editing: CardEditing?
    @Environment(Workspace.self) private var workspace

    var body: some View {
        Button("边聊边看", icon: .rightColumn) {
            workspace.attempt { [workspace, editing, cardID] in
                _ = try await editing?.flushed()
                workspace.pickDock(cardID)
            }
        }
        .disabled(editing?.text.isEmpty != false)
    }
}
#endif
