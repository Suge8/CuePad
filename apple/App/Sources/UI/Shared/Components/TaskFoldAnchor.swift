import SwiftUI

/// 项目页收起其余任务时，纸底那一行（"收起" → "还有 N 条"）留在原来的屏幕位置：收起与滚动在同一个事务里一步到位，偏移减去被收走的高度。
/// 被收走的高度 = 那一行此刻在内容里的位置 − 折起时它在内容里的位置（折起时记下；展开期间上面的任务有增减时差一两行）。
/// 偏移与位置随滚动每帧都变，只记在这个不触发更新的盒子里（ui.md「渲染性能约束」），收起那一下才读。Mac 与 iOS 共用。
/// 收起不带弹簧（两端都一步到位）：程序滚动的动画由滚动区自己按它的曲线走，跟布局的弹簧对不上，几千点的偏移一动，中途整页飞过卡片墙（iOS 27 录屏实测）。
/// 否决的方案：按 id `scrollTo` 回那一行——iOS 上在懒加载栈里与内容变短同一个事务的滚动被丢掉、夹到页底，挪到下一圈再滚又先跳到页底一帧；
/// 所以 iOS 的任务纸不放进页面的懒加载栈，放在它上面。
final class TaskFoldAnchor {
    fileprivate static let space = "taskFoldPage"
    fileprivate var offset: CGFloat = 0
    fileprivate var bar: CGFloat = 0
    fileprivate var foldedBar: CGFloat?

    /// 收起其余任务：一步到位，同一个事务里把滚动挪到让纸底那一行留在原处（还没见过折起的样子时不动滚动）。
    func collapse(_ fold: Binding<TaskFold>, scrolling position: Binding<ScrollPosition>) {
        let target = foldedBar.map { offset - (bar - $0) }
        withTransaction(\.disablesAnimations, true) {
            fold.wrappedValue.showsAll = false
            if let target { position.wrappedValue.scrollTo(y: target) }
        }
    }
}

extension View {
    /// 页面滚动区的内容：纸底那一行的位置在它的坐标里量。
    func taskFoldContent() -> some View {
        coordinateSpace(.named(TaskFoldAnchor.space))
    }

    /// 页面的滚动区：把偏移记进 `anchor`。
    func taskFoldScroll(_ anchor: TaskFoldAnchor) -> some View {
        // `scrollTo(y:)` 的 0 是内容顶到可见范围上沿（不含顶栏让出的内边距），量到的偏移要加回内边距才是同一个口径
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in anchor.offset = offset }
    }

    /// 纸底那一行：把它在内容里的位置记进 `anchor`，`folded` 时另记一份折起时的位置。
    func taskFoldBar(_ anchor: TaskFoldAnchor, folded: Bool) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TaskFoldAnchor.space)).minY } action: { y in
            anchor.bar = y
            if folded { anchor.foldedBar = y }
        }
    }
}
