#if os(iOS)
import SwiftUI

/// 任务浮窗：七成高起、可拉满，里面是这条任务（`TaskPage`：标题行、给 Agent 的话、进展）；
/// 发出记录与打开的下级都在浮窗里推进去，下拉收起。
struct TaskSheet: View {
    let id: UUID
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            CardEditorScreen(cardID: id, expectsTask: true)
                .navigationDestination(for: Navigation.Route.self) { route in
                    if case .card(let child) = route { CardEditorScreen(cardID: child) }
                }
        }
        // 起步高一点：正文、交给 Agent 与进展三块都放得下，可拉满
        .presentationDetents([.fraction(0.72), .large])
        // 整张浮窗是一张纸：顶栏与底边不露出系统的灰底
        .presentationBackground(palette.paper)
        .overlay {
            FloatingInput(isPresented: navigation.outbox != nil, close: { navigation.outbox = nil }) {
                if let outbox = navigation.outbox { HandOffInput(outbox: outbox).id(outbox.id) }
            }
        }
    }
}
#endif
