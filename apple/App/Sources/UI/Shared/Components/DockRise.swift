import SwiftUI

/// 浮在回复框上方的整卡（Cue 页的拍板卡、会话页的问题卡、出错与没能结束，三端同一份）从回复框那一排后面升起；会话页的整卡离开时沉回去（`DockedCard`），
/// 拍板卡答完浮着淡掉（理由在 `CueWaitDock.body`）。
/// 占的高随曲线在 0 与整高之间连续变，卡不透明、顶边跟着走，没露出的下半截齐那一排的上沿裁掉。
/// 底栏、对话让出的地方（手机是安全区，Mac 是浮着的回复框）与卡每一帧都是同一个高，贴着最新的对话跟着每帧让位、再跟着落回（`ChatScroll`），不当帧跳。
/// 只动卡（淡入淡出、平移）的话占的高当帧就到终点：对话先一下被顶开或掉下去，再空着等卡补上或淡完。代价是动的这零点几秒里底栏与对话每帧排一次
/// （会话页状态轮播、卡几秒进出一次，与改前交替 3 轮：唤醒与渲染服务持平，App 指令每次进出约多 3.5 亿条）。
/// 否决过：卡叠在对话上、对话底下常留一张卡的位置——卡高随问题与选项变，平时空着一大截；不留又盖住最新那几行（问的来龙去脉）。
/// 减弱动态效果时只淡入淡出（`floats`），高当帧到位。
struct RiseBehind: ViewModifier, Animatable {
    /// 露出的比例，0 是全藏在输入框后面。
    var shown: CGFloat
    /// 浮着（减弱动态效果、拍板卡答完离开）：不裁，占的高为 0 时卡往上浮在对话上（淡入淡出时用）。
    let floats: Bool
    /// 对话区可见的高：卡至多它的一半，再高在卡里滚。
    @Environment(\.chatHeight) private var chatHeight

    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    /// 一条路径排两种样子（换分支的话卡在离开那一下换了身份、重建一遍）：浮着时卡底对齐、往上浮出去，不裁；
    /// 不浮时两边与上面让出卡的影子（随露出的比例收，藏到底时一点不留），下沿齐输入框那一排的上沿裁——往下伸的话，
    /// 卡藏在下面的上沿与问号从输入框圆角外、"⋯"与输入框之间的缝里露出来，画在玻璃控件上面。
    func body(content: Content) -> some View {
        let limit = chatHeight / 2
        RiseLayout(shown: shown, floats: floats, limit: limit) { content }
            // 矩形裁剪，不用遮罩：遮罩每画一次都要渲染服务另开一遍离屏，卡停着时下面的计时、进展每次换字都付一次
            .clipShape(RiseClip(
                side: floats ? RiseBehind.shadowRoom : RiseBehind.shadowRoom * shown,
                top: floats ? limit + RiseBehind.shadowRoom : RiseBehind.shadowRoom * shown))
    }

    private static let shadowRoom: CGFloat = 24
}

/// `RiseBehind` 的裁剪：两边与上面往外让出 `side`、`top`，下沿齐自己的下沿。
private nonisolated struct RiseClip: Shape {
    let side: CGFloat
    let top: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - side, y: rect.minY - top, width: rect.width + 2 * side, height: rect.height + top))
    }
}

/// 会话页浮在回复框上方的一张整卡（问题卡、出错、没能结束，两端同一份）：`item` 有了升起、没了沉回（`RiseBehind`），沉的这一段还画它最后的样子。
/// 不用转场：拿掉的视图不进排版，占的高当帧就没了，对话照样一跳。页打开时已经在的随页排出来、不升起；没有卡时什么都不排。
/// 曲线是定长的 `Motion.glide`：这一段底栏与对话每帧都要排，弹簧收尾那一两像素还要多排两百多毫秒。
/// 卡与下面回复框（或下一张卡）之间的缝在这里，算在升起的那一截里：缝跟着卡长、跟着收，缝里的影子不被裁掉。
/// Cue 页的拍板卡另有滑卡换件与叠边，自己驱动 `RiseBehind`（`CueWaitDock`）。
struct DockedCard<Item: Equatable, Card: View>: View {
    let item: Item?
    @ViewBuilder let card: (Item) -> Card
    /// 正在沉回去的那张最后的样子；不在沉为 nil。
    @State private var last: Item?
    /// 露出的比例（`RiseBehind`）；减弱动态效果时是不透明度。
    @State private var level: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ item: Item?, @ViewBuilder card: @escaping (Item) -> Card) {
        self.item = item
        self.card = card
        _level = State(initialValue: item == nil ? 0 : 1)
    }

    var body: some View {
        // 外面这一层一直在（空着时不占地方）：`onChange` 挂在它上面，卡出现的那一次也接得到
        ZStack {
            if let shown = item ?? last {
                card(shown).padding(.bottom, Spacing.item)
                    .opacity(reduceMotion ? level : 1)
                    .modifier(RiseBehind(shown: reduceMotion ? (item == nil ? 0 : 1) : level, floats: reduceMotion))
            }
        }
        .onChange(of: item) { old, new in
            if new == nil, let old { leave(old) } else if old == nil, new != nil { arrive() }
        }
    }

    /// 与沉回同一帧起播（不像 `CueWaitDock` 等卡排进去的下一帧）：一张走、一张来（问题答完转出错）时两段同起同落，占的高一路单调地变，
    /// 晚一帧的话对话先多掉一截再往回爬。沉到一半又来了就从那儿升回去。
    private func arrive() {
        last = nil
        withAnimation(Motion.fading(Motion.glide, reduceMotion: reduceMotion)) { level = 1 }
    }

    private func leave(_ old: Item) {
        last = old
        withAnimation(Motion.fading(Motion.glide, reduceMotion: reduceMotion), completionCriteria: .removed) { level = 0 } completion: {
            if item == nil { last = nil }
        }
    }
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
