#if os(macOS)
import SwiftUI

/// 进展页（侧栏"进展"、⌘⇧T）：看板（`TaskBoardPage`）与会话（`SessionsPane`）两段，看哪一段只有 `Workspace.progressPane` 一份。
/// 页里不另起一排，都在窗口最顶那一排：左上是两段的图标分段（`PanesSlot`，两段同一个位置）；看板段那一排其余是四个列头（`boardTopRow`，
/// 待办的列头让出分段那一截），范围、新任务、搜索收在右上"⋯"；会话段是项目范围（`ScopeSlot`）与右边的新会话（`PageActionSlot`）。
/// 被否决的：分段、范围、新任务和四个列头挤在同一排——1440 宽的窗口里互相压住，最右那一列只剩 40pt 写列头。
/// 新会话的表单挂在这一页（`NewSessionPanel`，⌥⌘N 先来这一段再弹它）。
/// 去过的段一直挂着，换段只换哪一段看得见（同 `PageStack` 换页）：按段现建时换一下要重建整块看板或会话列表（实测 75～125ms）。
/// 看不见的那段暂停订阅与实时状态（`pageActive`）。
struct ProgressPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.pageActive) private var active
    @State private var mounted: Set<ProgressPane> = []

    var body: some View {
        let shown = workspace.progressPane
        ZStack {
            if mounted.contains(.board) || shown == .board { pane(.board, shown) { TaskBoardPage() } }
            if mounted.contains(.sessions) || shown == .sessions { pane(.sessions, shown) { SessionsPane() } }
        }
        .onChange(of: shown, initial: true) { mounted.insert(shown) }
        .modifier(NewSessionPanel())
    }

    private func pane(_ pane: ProgressPane, _ shown: ProgressPane, @ViewBuilder content: () -> some View) -> some View {
        let on = pane == shown
        return content()
            .opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
            .environment(\.pageActive, active && on)
    }
}

#endif
