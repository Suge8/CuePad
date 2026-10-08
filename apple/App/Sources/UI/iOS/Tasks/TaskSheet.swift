#if os(iOS)
import SwiftUI

/// 任务浮窗：七成高起、可拉满，里面是这条任务（`TaskPage`：标题、提示词、子任务）；
/// 打开的提示词与子任务都在浮窗里推进去，下拉收起。
struct TaskSheet: View {
    let id: UUID
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            CardEditorScreen(cardID: id, expectsTask: true)
        }
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
