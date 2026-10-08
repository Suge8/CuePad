#if os(macOS)
import SwiftUI

extension View {
    /// 根页的滚动区：滚动时把位置报给工作区（离开这一页时记进历史），返回、前进到这一页时滚回离开时的位置。
    /// 只记一个数而不是让离开的页一直挂着：挂着的页照样订阅资料库、留着整页视图与图片，几页下来开销远大于一个偏移。
    /// 数据是异步读到的：内容长到够滚到那里时才滚过去。
    func remembersScroll() -> some View { modifier(RemembersScroll()) }
}

private struct RemembersScroll: ViewModifier {
    @Environment(Workspace.self) private var workspace
    @State private var position = ScrollPosition()
    /// 还没滚回去的位置。
    @State private var pending: CGFloat?

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onAppear { pending = workspace.takeRestoredScroll() }
            // 内容再也长不到那里（离开后删了东西）时，用户一动手就不再等
            .onScrollPhaseChange { _, phase in if phase == .interacting { pending = nil } }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, y in
                if pending == nil { workspace.scrolled(to: y) }
            }
            .onScrollGeometryChange(for: CGFloat.self) { $0.contentSize.height - $0.containerSize.height } action: { _, reach in
                guard let target = pending, reach >= target else { return }
                pending = nil
                position.scrollTo(y: target)
            }
    }
}
#endif
