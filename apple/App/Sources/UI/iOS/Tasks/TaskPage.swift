#if os(iOS)
import CueStore
import SwiftUI

/// 任务页（推入的整页纸，同灵感的纸页）：悬浮顶栏中间写它在哪个项目，右边"⋯"；内容最上面是完成圈与任务的标题（`TaskHeading`）；
/// 主体是提示词卡片（`PromptList`）——点开是灵感的大编辑区，卡上就地发给 Agent，末尾写一条新的并直接进入编辑；
/// 步骤在提示词之后（`SubtaskList`）；有步骤的任务没有提示词（叶子才有一条草稿，步骤自己的页就是叶子的页）。提示词与步骤都推进同一个导航栈。
struct TaskPage: View {
    let card: Card
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(Navigation.self) private var navigation
    @State private var detail: TaskDetail?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                // 完成圈的点按区比图形大，往左伸进页边距，图形仍与下面的内容对齐
                HStack(alignment: .top, spacing: 4) {
                    GoalCheck(task: card, subtasks: detail?.progress).offset(y: -8)
                    TaskHeading(task: card).padding(.top, 2)
                }
                .padding(.leading, -8)
                if detail?.subtasks.isEmpty != false {  // 草稿只在叶子上：有步骤的任务把它放在步骤里
                    PromptList(task: card, detail: detail, open: { navigation.push(.card($0.id)) }, hand: { navigation.handToAgent($0) }, write: write)
                }
                SubtaskList(detail: detail, open: { navigation.push(.card($0.id)) })
            }
            .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 40)
        }
        .scrollDismissesKeyboard(.interactively)
        .floatingHeader(workspace.catalog?.project(card.projectID)?.name ?? CaptureCopy.unfiled) { more }
        .observing(services.store, id: card.id, into: $detail, onError: workspace.fail) { [id = card.id] in
            try TaskDetail.read(id, from: $0)
        }
    }

    private var more: some View {
        Menu { CardActions(card: card, more: true) } label: { Image(systemName: "ellipsis") }
            .accessibilityLabel("更多")
    }

    /// 写一条提示词：先建好，直接进入它的编辑。
    private func write() {
        let task = card.id
        workspace.attempt { navigation.push(.card(try await workspace.services.store.createCard(body: "", under: task).id)) }
    }
}
#endif
