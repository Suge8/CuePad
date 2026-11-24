import SwiftUI

struct RiseBehind: ViewModifier, Animatable {
    var shown: CGFloat
    let floats: Bool
    @Environment(\.chatHeight) private var chatHeight

    var animatableData: CGFloat {
        get { shown }
        set { shown = newValue }
    }

    func body(content: Content) -> some View {
        let limit = chatHeight / 2
        RiseLayout(shown: shown, floats: floats, limit: limit) { content }
            // 矩形裁剪，不用遮罩：遮罩每画一次都要渲染服务另开一遍离屏，卡停着时下面的计时、进展每次换字都付一次
            .clipShape(RiseClip(
                side: floats ? Elevation.lifted.reach : Elevation.lifted.reach * shown,
                top: floats ? limit + Elevation.lifted.reach : Elevation.lifted.reach * shown))
    }
}

private nonisolated struct RiseClip: Shape {
    let side: CGFloat
    let top: CGFloat

    func path(in rect: CGRect) -> Path {
        Path(CGRect(x: rect.minX - side, y: rect.minY - top, width: rect.width + 2 * side, height: rect.height + top))
    }
}

/// 不用转场：拿掉的视图不进排版，占的高当帧就没了，对话照样一跳。页打开时已经在的随页排出来、不升起；没有卡时什么都不排。
/// 曲线是定长的 `Motion.glide`：这一段底栏与对话每帧都要排，弹簧收尾那一两像素还要多排两百多毫秒。
/// 卡与下面回复框（或下一张卡）之间的缝在这里，算在升起的那一截里：缝跟着卡长、跟着收，缝里的影子不被裁掉。
struct DockedCard<Item: Equatable, Card: View>: View {
    let item: Item?
    @ViewBuilder let card: (Item) -> Card
    @State private var last: Item?
    @State private var level: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(_ item: Item?, @ViewBuilder card: @escaping (Item) -> Card) {
        self.item = item
        self.card = card
        _level = State(initialValue: item == nil ? 0 : 1)
    }

    var body: some View {
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

struct RiseLayout: Layout {
    let shown: CGFloat
    let floats: Bool
    let limit: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let child = subviews.first else { return .zero }
        let size = child.sizeThatFits(ProposedViewSize(width: proposal.width, height: room(proposal.height)))
        return CGSize(width: proposal.width ?? size.width, height: size.height * shown)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let child = subviews.first else { return }
        let fit = ProposedViewSize(width: bounds.width, height: room(proposal.height))
        let size = child.sizeThatFits(fit)
        let origin = floats ? CGPoint(x: bounds.minX, y: bounds.maxY - size.height) : bounds.origin
        child.place(at: origin, anchor: .topLeading, proposal: fit)
    }

    private func room(_ offered: CGFloat?) -> CGFloat {
        guard let offered, shown > 0 else { return limit }
        return min(limit, (offered / shown).rounded(.up))
    }
}
