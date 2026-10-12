#if os(iOS)
import CueStore
import SwiftUI

/// 任务页（任务浮窗里、或整页推入）：顶上是完成圈与任务的标题（`TaskHeading`），右上"⋯"；
/// 主体是提示词卡片（`PromptList`）——点开是灵感的大编辑区，卡上就地发给 Agent，末尾写一条新的并直接进入编辑；
/// 步骤在提示词之后（`SubtaskList`）。步骤自己的页只有标题（步骤是勾选清单里的一条，没有提示词）。提示词与步骤都在这一页的导航里推进去。
struct TaskPage: View {
    let card: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @State private var detail: TaskDetail?
    @State private var opened: UUID?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 完成圈与"⋯"的点按区比图形大，往两边伸进页边距，图形仍与下面的内容对齐
                HStack(alignment: .top, spacing: 4) {
                    TaskRingButton(task: card, prompts: detail?.prompts.count ?? 0, subtasks: detail?.progress).offset(y: -8)
                    TaskHeading(task: card).padding(.top, 2)
                    more.offset(y: -8)
                }
                .padding(.horizontal, -8)
                if card.parentID == nil {
                    PromptList(task: card, detail: detail, open: { opened = $0.id }, hand: { navigation.handToAgent($0) }, write: write)
                }
                SubtaskList(detail: detail, open: { opened = $0.id })
            }
            .padding(.horizontal, 16).padding(.top, 20).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(palette.paper)
        .toolbar(.hidden, for: .navigationBar)
        .navigationDestination(item: $opened) { CardEditorScreen(cardID: $0) }
        .observing(services.store, id: card.id, into: $detail, onError: workspace.fail) { [id = card.id] in
            try TaskDetail.read(id, from: $0)
        }
    }

    private var more: some View {
        Menu("更多", systemImage: "ellipsis") { CardActions(card: card, more: true) }
            .labelStyle(.iconOnly)
            .font(.body.weight(.semibold)).foregroundStyle(palette.ink2)
            .frame(width: 44, height: 44).contentShape(.rect)
    }

    /// 写一条提示词：先建好，直接进入它的编辑。
    private func write() {
        let task = card.id
        workspace.attempt { opened = try await workspace.services.store.createCard(body: "", under: task).id }
    }
}
#endif
