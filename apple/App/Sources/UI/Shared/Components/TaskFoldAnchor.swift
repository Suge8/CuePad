import SwiftUI

/// 项目页收起其余任务时，纸底那一行（"收起" → "还有 N 条"）留在原来的屏幕位置：收起与滚动在同一个事务里一步到位，偏移减去被收走的高度。
/// 被收走的高度 = 那一行此刻在内容里的位置 − 收起后它该在的位置；后者是折起时列出的那几条顶层任务最后一行的下沿
/// （大纲在内容里的上沿 + 那一行在大纲里的下沿，后者借大纲本来就为拖放量着的行位置，`rowFrame`，不给每行另挂东西），
/// 展开时它就在列表里、随上面任务的增减实时挪，所以展开期间上面的任务变了也准。
/// 偏移与位置随滚动每帧都变，只记在这个不触发更新的盒子里（ui.md「渲染性能约束」），收起那一下才读。Mac 与 iOS 共用。
/// 两端收起都一步到位，iOS 也不随弹簧：锚定纸底那一行优先于弹簧（iOS 只让纸上留下的几行淡入）。否决的方案：滚动随收起的弹簧一起动——
/// 程序滚动的动画由滚动区自己按它的曲线走，跟布局的弹簧对不上，几千点的偏移一动，中途整页飞过卡片墙（iOS 27 录屏实测）。
/// 否决的方案：按 id `scrollTo` 回那一行——iOS 上在懒加载栈里与内容变短同一个事务的滚动被丢掉、夹到页底；收起后量那一行的新位置再滚——
/// 懒加载的大纲先报一个按估算排的位置，拿它滚就滚错。iOS 的任务纸也因此不放进页面的懒加载栈，放在它上面。
final class TaskFoldAnchor {
    fileprivate static let space = "taskFoldPage"
    fileprivate var offset: CGFloat = 0
    fileprivate var bar: CGFloat = 0
    fileprivate var outlineTop: CGFloat = 0
    private var rows: [UUID: CGFloat] = [:]
    private static let lowestTarget: CGFloat = 1

    /// 大纲报来的一行位置（大纲自己的坐标），记下沿。
    func rowFrame(_ id: UUID, _ frame: CGRect) { rows[id] = frame.maxY }

    /// 收起其余任务：一步到位，同一个事务里把滚动挪到让纸底那一行留在原处。`boundary` 是折起时列出的最后一行（`TaskFold.lastFolded`）。
    func collapse(_ fold: Binding<TaskFold>, boundary: UUID?, scrolling position: Binding<ScrollPosition>) {
        // 页面停在顶上时不用滚：收走的都在纸底那一行上面，留不住它，也不会被夹到别处
        let target = offset > 0 ? boundary.flatMap { rows[$0] }.map { offset - (bar - (outlineTop + $0)) } : nil
        withTransaction(\.disablesAnimations, true) {
            fold.wrappedValue.showsAll = false
            // 纸底那一行在窗口里比收起后它上面剩下的内容还低时留不住，退到页顶。不用 0 或 `edge(.top)`：与内容变短同一个事务时
            // 它们被丢掉，滚动停在旧偏移、随后夹到页底（macOS 27 实测）；1 点照常生效，差的这一点看不出来。
            if let target { position.wrappedValue.scrollTo(y: max(Self.lowestTarget, target)) }
        }
    }
}

extension View {
    /// 页面滚动区的内容：纸底那一行与分界的位置在它的坐标里量。
    func taskFoldContent() -> some View {
        coordinateSpace(.named(TaskFoldAnchor.space))
    }

    /// 页面的滚动区：把偏移记进 `anchor`。
    func taskFoldScroll(_ anchor: TaskFoldAnchor) -> some View {
        // `scrollTo(y:)` 的 0 是内容顶到可见范围上沿（不含顶栏让出的内边距），量到的偏移要加回内边距才是同一个口径
        onScrollGeometryChange(for: CGFloat.self) { $0.contentOffset.y + $0.contentInsets.top } action: { _, offset in anchor.offset = offset }
    }

    /// 纸底那一行：把它在内容里的位置记进 `anchor`。
    func taskFoldBar(_ anchor: TaskFoldAnchor) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TaskFoldAnchor.space)).minY } action: { anchor.bar = $0 }
    }

    /// 任务纸里的大纲：把它在内容里的上沿记进 `anchor`。
    func taskFoldOutline(_ anchor: TaskFoldAnchor) -> some View {
        onGeometryChange(for: CGFloat.self) { $0.frame(in: .named(TaskFoldAnchor.space)).minY } action: { anchor.outlineTop = $0 }
    }
}
