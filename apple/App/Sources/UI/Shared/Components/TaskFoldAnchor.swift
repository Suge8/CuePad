import SwiftUI

/// 项目页收起其余任务时，纸底那一行（"收起" → "还有 N 条"）留在原来的屏幕位置：收起照常一步到位，收起后的版面一排好（那一行的位置变了），
/// 就在那次位置回调里按 id 滚回它收起前在可见区里的位置（`scrollTo(id:anchor:)`，锚点由那个位置换算）。Mac 与 iOS 共用。
/// 留不住时（那一行收起前比收起后页顶时它的位置还低）系统夹到页顶。那一行的位置随滚动在变，只记在这个不触发更新的盒子里，收起那一下才读。
/// 两个前提（iOS 27、macOS 27 实测）：收起后的大纲高度当场是准的——懒加载栈对没建的行只报估算的高度，Mac 上按 id 滚到的位置会偏几千点，
/// 所以折起时列出的行放在大纲的普通栈部分（`TaskOutline.lazyAfter`）；任务纸不进页面的懒加载栈——纸在懒加载栈的一格里时，滚到的位置偏出一屏（-644 对 243）。
/// 否决的方案：滚动与收起放在同一个事务里（按偏移或按 id）——系统时灵时不灵，Mac 上 0/20；等下一帧再滚——先画出几帧页底（iOS 录屏约 50ms 的闪）；
/// 滚动随收起的弹簧一起动——程序滚动的动画跟布局的弹簧对不上，中途整页飞过卡片墙。
final class TaskFoldAnchor {
    fileprivate static let barID = "taskFoldBar"
    /// 滚动区的高度（含顶栏、底栏底下那一截：`scrollTo(id:anchor:)` 的锚点按整个滚动区算，Mac 与 iOS 实测）：只随窗口变，不随滚动变。
    fileprivate var height: CGFloat = 0
    /// 页面停在顶上：收起时不用滚（收走的都在那一行上面，留不住也不会被夹到别处），也就不多一次整页更新。
    fileprivate var atTop = true
    /// 纸底那一行在滚动区里的位置。
    fileprivate var bar: CGRect?
    /// 收起后等着发的滚动。
    private var pending: (() -> Void)?

    /// 收起其余任务：一步到位，版面一排好就把纸底那一行滚回收起前的位置。
    func collapse(_ fold: Binding<TaskFold>, scrolling position: Binding<ScrollPosition>) {
        guard let bar, !atTop else { return withTransaction(\.disablesAnimations, true) { fold.wrappedValue.showsAll = false } }
        // 锚点 u：那一行上沿 + u × 行高 对齐滚动区上沿 + u × 滚动区高，解出让上沿留在原处的 u
        let room = height - bar.height
        let anchor = UnitPoint(x: 0, y: room > 0 ? bar.minY / room : 0)
        pending = { withTransaction(\.disablesAnimations, true) { position.wrappedValue.scrollTo(id: Self.barID, anchor: anchor) } }
        withTransaction(\.disablesAnimations, true) { fold.wrappedValue.showsAll = false }
    }

    fileprivate func moved(_ frame: CGRect) {
        bar = frame
        guard let pending else { return }
        self.pending = nil
        pending()
    }
}

extension View {
    /// 页面的滚动区：把它的高度、停没停在顶上记进 `anchor`（两样都不随滚动每帧变）。
    func taskFoldScroll(_ anchor: TaskFoldAnchor) -> some View {
        onScrollGeometryChange(for: CGFloat.self) { $0.containerSize.height } action: { _, height in anchor.height = height }
            .onScrollGeometryChange(for: Bool.self) { $0.contentOffset.y <= -$0.contentInsets.top } action: { _, top in anchor.atTop = top }
    }

    /// 纸底"还有 N 条 / 收起"那一行：滚回去的目标，把它在滚动区里的位置记进 `anchor`。
    func taskFoldBar(_ anchor: TaskFoldAnchor) -> some View {
        id(TaskFoldAnchor.barID)
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .scrollView) } action: { anchor.moved($0) }
    }
}
