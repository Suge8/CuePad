#if os(iOS)
import SwiftUI

/// 任务浮窗：半屏起、可拉满，里面是这条任务的纸页（正文就是交给 Agent 的话，上方是状态、会话与下级，见 `TaskPanel`）；
/// 点下级在浮窗里推进去，下拉收起。
struct TaskSheet: View {
    let id: UUID
    @Environment(Navigation.self) private var navigation

    var body: some View {
        @Bindable var navigation = navigation
        NavigationStack {
            CardEditorScreen(cardID: id)
                .navigationDestination(for: Navigation.Route.self) { route in
                    if case .card(let child) = route { CardEditorScreen(cardID: child) }
                }
        }
        .presentationDetents([.medium, .large])
        .sheet(item: $navigation.outbox) { SessionPicker(outbox: $0) }
    }
}
#endif
