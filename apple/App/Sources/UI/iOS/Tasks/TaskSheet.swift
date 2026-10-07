#if os(iOS)
import SwiftUI

/// 任务浮窗：半屏起、可拉满，里面是这条任务（`TaskPage`：正文就是给 Agent 的话，周围是状态、Agent 与下级）；
/// 发出记录、下级与打开的下级都在浮窗里推进去，下拉收起。
struct TaskSheet: View {
    let id: UUID
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            CardEditorScreen(cardID: id, expectsTask: true)
                .navigationDestination(for: Navigation.Route.self) { route in
                    if case .card(let child) = route { CardEditorScreen(cardID: child) }
                }
        }
        .presentationDetents([.medium, .large])
        // 整张浮窗是一张纸：顶栏与底边不露出系统的灰底
        .presentationBackground(palette.paper)
        .sheet(item: $navigation.outbox) { SessionPicker(outbox: $0) }
    }
}
#endif
