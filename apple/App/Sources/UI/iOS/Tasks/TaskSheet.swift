#if os(iOS)
import SwiftUI

/// 任务浮窗：七成高起、可拉满，里面是这条任务（`TaskPage`：标题、提示词、子任务）。
/// 仍是七成高起：一眼看完这条任务、背后的书架还在，下拉就回去（拉满或整页推入都会丢掉"背后是哪"的上下文）；
/// 七成高时系统浮窗是悬空的、四角圆，下沿的内容在圆角那一段淡出，不被硬裁。
/// 打开的提示词与子任务都在浮窗里推进去，下拉收起。
struct TaskSheet: View {
    /// 下安全区（主屏指示条那一段）之上再让出的高度：加起来约是浮窗底角圆弧的高度。
    private static let cornerClearance: CGFloat = 18
    let id: UUID
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        NavigationStack {
            CardEditorScreen(cardID: id, expectsTask: true)
                // 七成高时浮窗四角都是屏幕那么大的圆角：内容滚到下沿时不让圆角硬裁掉一行，而是在圆角那一段里淡出
                // （同栏下的淡出，只是透明度）；让出的高度也够最后一行停在圆角之上
                .fadesUnderBars(bottom: true)
                .safeAreaPadding(.bottom, Self.cornerClearance)
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
