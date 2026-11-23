import SwiftUI

/// 钮在上、内容在它下面长出来。
struct Fold<Label: View, Content: View>: View {
    @Binding var open: Bool
    var toggles = true
    var press = FoldPress.inline
    @ViewBuilder let label: Label
    @ViewBuilder let content: Content
    @Environment(\.chatStay) private var stay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var key = UUID()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            FoldToggle(open: open, toggles: toggles, press: press) {
                stay?.stay(key, !open)
                withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { open.toggle() }
            } label: {
                label
            }
            VStack(alignment: .leading, spacing: 0) { content }.clipsFold()
        }
        .onDisappear { if open { stay?.stay(key, false) } }
    }
}

/// 钮在底边：折着时也露一截（`content(false)`），展开是 `content(true)`。开合时钮与它底下的都不动、内容朝上长：钮留在指针下，再点一下原样收回。
/// 高是一帧帧真的在变（`Unfolding`），不是排版一步到位、画面补间：对话的滚动区按底边锚定只认真的内容高，补间的那种它第一帧就把偏移挪到头，
/// 再靠整段上滑（`ContentLift`）补回来，两条曲线对不上，钮底下的那些先被推下去再回来。
struct RisingFold<Label: View, Content: View>: View {
    @Binding var open: Bool
    var alignment = HorizontalAlignment.leading
    var press = FoldPress.inline
    @ViewBuilder let label: Label
    @ViewBuilder let content: (_ unfolded: Bool) -> Content
    @Environment(\.chatStay) private var stay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var key = UUID()

    var body: some View {
        VStack(alignment: alignment, spacing: 0) {
            Unfolding(phase: open ? 1 : 0, folded: content(false), unfolded: content(true)).clipsFold()
            FoldToggle(open: open, press: press) {
                stay?.grow(key, true)
                // 等弹簧的尾巴也走完（`.removed`）：按"看着到了"算的话最后那几点高滚动区已经不管，钮跟着挪开
                withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion), completionCriteria: .removed) { open.toggle() } completion: {
                    stay?.grow(key, false)
                }
            } label: {
                label
            }
        }
    }
}

enum FoldPress { case inline, row }

private struct FoldToggle<Label: View>: View {
    let open: Bool
    var toggles = true
    let press: FoldPress
    let toggle: () -> Void
    @ViewBuilder let label: Label

    var body: some View {
        Group {
            switch press {
            case .inline: Button(action: toggle) { label }.buttonStyle(PressStyle(.inline))
            case .row: Button(action: toggle) { label }.buttonStyle(.row)
            }
        }
        // 没有可开的时只是不接点按，不停用：停用的按钮 iOS 整块压淡
        .allowsHitTesting(toggles)
        .accessibilityExpanded(toggles ? open : nil)
    }
}

/// 展开的那份只在开着、开合到一半时在：收起的那一段它还整份留着，由变矮的框从底下一行行收掉，到头才换回折着的那份。
private struct Unfolding<Content: View>: View, Animatable {
    var phase: CGFloat
    let folded: Content
    let unfolded: Content

    var animatableData: CGFloat {
        get { phase }
        set { phase = newValue }
    }

    var body: some View {
        UnfoldingHeight(phase: phase) {
            VStack(alignment: .leading, spacing: 0) { folded }.opacity(phase > 0 ? 0 : 1).readerHidden(phase > 0)
            if phase > 0 { VStack(alignment: .leading, spacing: 0) { unfolded } }
        }
    }
}

private struct UnfoldingHeight: Layout {
    let phase: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) }
        guard let folded = sizes.first, let unfolded = sizes.last else { return .zero }
        return CGSize(width: max(folded.width, unfolded.width), height: folded.height + (unfolded.height - folded.height) * phase)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews {
            subview.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

extension View {
    /// 行的悬停底比字宽出一圈（`PressStyle`），裁的时候两侧给它留出来。
    func clipsFold() -> some View {
        padding(.horizontal, Spacing.item).clipped().padding(.horizontal, -Spacing.item)
    }
}

extension View {
    func fadesEdge(_ edge: VerticalEdge, when folded: Bool) -> some View {
        mask {
            ZStack(alignment: edge == .top ? .top : .bottom) {
                Rectangle()
                LinearGradient(colors: [.clear, .black], startPoint: edge == .top ? .bottom : .top, endPoint: edge == .top ? .top : .bottom)
                    .frame(height: Note.lineHeight).blendMode(.destinationOut).opacity(folded ? 1 : 0)
            }
            .compositingGroup()
        }
    }
}

struct DisclosureChevron: View {
    let open: Bool
    @Environment(\.palette) private var palette

    var body: some View {
        Image(.expand).font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
            .rotationEffect(.degrees(open ? 180 : 0))
            .readerHidden(true)
    }
}
