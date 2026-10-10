#if os(iOS)
import SwiftUI

/// 任务浮窗：里面是这条任务（`TaskPage`：标题、提示词、子任务），打开的提示词与子任务都在浮窗里推进去，下拉收起。
/// 一开就是满高：系统不满高的浮窗是悬空的，下沿与两侧总露出一条压暗的书架，背后那一截书架也读不到什么；
/// 满高的浮窗贴住屏幕下沿，背后是哪由顶上露出的那一线与下拉手势交代。下沿的内容在主屏指示条那一段淡出。
struct TaskSheet: View {
    let id: UUID
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            CardEditorScreen(cardID: id, expectsTask: true)
                // 内容滚到屏幕下沿时在指示条那一段淡出，不被屏幕圆角硬裁（同栏下的淡出，只是透明度）
                .fadesUnderBars(bottom: true)
        }
        .presentationDetents([.large])
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
