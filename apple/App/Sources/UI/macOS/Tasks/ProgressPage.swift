#if os(macOS)
import SwiftUI

/// 进展页（侧栏"进展"、⌘⇧T）：看板（`TaskBoardPage`）与会话（`SessionsPane`）两段，看哪一段只有 `Workspace.progressPane` 一份。
/// 分段、范围与新建在本页顶上，四个列头跟各自的列对齐。
/// 新会话的表单挂在这一页（`NewSessionPanel`，⌥⌘N 先来这一段再弹它）。
/// 去过的段一直挂着，换段只换哪一段看得见（同 `PageStack` 换页）：按段现建时换一下要重建整块看板或会话列表（实测 75～125ms）。
/// 看不见的那段暂停订阅与实时状态（`pageActive`）。
struct ProgressPage: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.pageActive) private var active
    @State private var mounted: Set<ProgressPane> = []

    var body: some View {
        let shown = workspace.progressPane
        VStack(spacing: 0) {
            HStack { ProgressPanes(); ScopeSlot(); Spacer(); PageActionSlot() }.padding(.horizontal, 16).frame(height: 44)
            ZStack {
                if mounted.contains(.board) || shown == .board { pane(.board, shown) { TaskBoardPage() } }
                if mounted.contains(.sessions) || shown == .sessions { pane(.sessions, shown) { SessionsPane() } }
            }
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
