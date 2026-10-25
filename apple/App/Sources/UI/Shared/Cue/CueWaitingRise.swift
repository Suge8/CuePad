import SwiftUI

/// 拍板卡从输入框那一排后面升起：占的高随曲线从 0 长到整高，卡不透明、顶边跟着上来，没露出的下半截齐那一排的上沿裁掉。
/// 占的高本身在变，底栏、对话让出的地方（手机是安全区，Mac 是浮着的回复框）与卡每一帧都是同一个高：
/// 只动卡（淡入、平移）的话底栏当帧就是整高，对话先一下被顶开、空着等卡补进来。代价是这 0.25 秒里底栏每帧排一次，对话只跟着挪偏移。
/// 离开不走这条（`CueWaitDock.follow`）：浮着淡掉。
struct RiseBehind: ViewModifier, Animatable {
    /// 露出的比例，0 是全藏在输入框后面。
    var shown: CGFloat
    /// 浮着（减弱动态效果、答完离开）：不裁，占的高为 0 时卡往上浮在对话上（淡入淡出时用）。
    let floats: Bool
    /// 卡至多这么高（对话区可见高的一半），再高在卡里滚。
    let limit: CGFloat

    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    /// 一条路径排两种样子（换分支的话卡在离开那一下换了身份、重建一遍）：浮着时卡底对齐、往上浮出去，不裁；
    /// 不浮时两边与上面让出卡的影子（随露出的比例收，藏到底时一点不留），下沿齐输入框那一排的上沿裁——往下伸的话，
    /// 卡藏在下面的上沿与问号从输入框圆角外、"⋯"与输入框之间的缝里露出来，画在玻璃控件上面。
    func body(content: Content) -> some View {
        RiseLayout(shown: shown, floats: floats, limit: limit) { content }
            .mask {
                Rectangle()
                    .padding(.horizontal, -RiseBehind.shadowRoom * (floats ? 1 : shown))
                    .padding(.top, floats ? -(limit + RiseBehind.shadowRoom) : -RiseBehind.shadowRoom * shown)
            }
    }

    private static let shadowRoom: CGFloat = 24
}

/// 按露出的比例占高，孩子按整高顶对齐排：顶边随占的高上下，下半截在外面；浮着时底对齐，多出的往上浮。
struct RiseLayout: Layout {
    let shown: CGFloat
    let floats: Bool
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: room(proposal.height)))
        // 宽照给的：卡拿掉的那一刻孩子没了，宽跟着塌成 0 的话，裁的窗口两边让出的影子位就成了一小块露在输入框上
        return CGSize(width: proposal.width ?? size.width, height: size.height * shown)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let fit = ProposedViewSize(width: bounds.width, height: room(proposal.height))
        let size = child.sizeThatFits(fit)
        let origin = floats ? CGPoint(x: bounds.minX, y: bounds.maxY - size.height) : bounds.origin
        child.place(at: origin, anchor: .topLeading, proposal: fit)
    }

    /// 孩子按整高排：至多 `limit`，外面给的不够时（输入框先拿走它的高，剩下的不到 `limit`）只到给的。给的是露出的那截，
    /// 除以露出的比例换回整高：升起时外面按缩了的高回头再排一次，照给的高直接排的话卡里那段就当成放不下、换成紧凑的。
    /// 向上取整：除回来的小数比整高少一点点也会被当成放不下。
    private func room(_ offered: CGFloat?) -> CGFloat {
        guard let offered, shown > 0 else { return limit }
        return min(limit, (offered / shown).rounded(.up))
    }
}

/// 地方不够时先让的一段：给了高时按里面的理想高（滚动区是它内容的高）、至多到给的高（滚动区本身会占满给的高，留下一截空白）；
/// 量理想高时（`ViewThatFits` 挑哪一档、外面不给高）不占高，所以它放不放得下不影响挑哪一档。
struct Yielding: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let ideal = subviews[0].sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: proposal.height.map { min(ideal.height, $0) } ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
