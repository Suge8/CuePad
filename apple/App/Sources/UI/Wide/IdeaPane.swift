import CueEditor
import CueStore
import SwiftUI

/// 宽屏上的一条灵感，只此一份：并排的一块、点开盖在页上的那一层（`CoverLayer`）都是它。
/// 盖着时（`covers`）它还不是这一排里的一块：收起是合上这一层，胶囊旁多一颗钮把它放到旁边并排。
struct IdeaPane: View {
    let cardID: UUID
    var covers = false
    let close: () -> Void
    /// 编辑器挂上后的下一帧报一次：盖上来的那一层等它再淡入。
    var ready: (() -> Void)?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var card: Card?
    @State private var editing: CardEditing?
    @State private var sharing = InspirationSharing()

    var body: some View {
        ZStack(alignment: .top) {
            if let card, let editing {
                editor(card, editing).padding(.top, Chrome.band + Spacing.item)
            }
            head
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(palette.desk)
        .modifier(InspirationSharePresentation(sharing: sharing, editing: editing))
        .ideaEditing(cardID, card: $card, editing: $editing, made: { editing in
            Task {
                await NextFrame.wait()
                if covers, editing.initialText.isEmpty { editing.handle.focus() }
                ready?()
            }
        }, gone: close)
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
            PaneTitle(crumb: .init(card.flatMap { workspace.catalog?.project($0.projectID) }, in: workspace), title: editing?.title ?? "", handle: .card(cardID), close: close) {
                if let card, let editing { InspirationEditorActions(card: card, editing: editing, sharing: sharing) }
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
