#if os(iOS)
import SwiftUI

/// 开没开由调用方持有，`head` 里的按钮经 `grow` 开合。
/// 里面的高度只在开合时变：长大的动画里挨一下不带动画的改高，整块玻璃就有几帧不画。面板能长到的高不让键盘：键盘起落时里面不跟着重排（Cue 的名牌开面板前先收起键盘，按的是收完的高）。
/// 只放在页自己画的那一排里（窄屏的 Cue 页、iPad 右侧的 Cue 面板，`HeaderHost`）。额度不用它：额度是从钮长出的居中浮窗（`popup`）。
struct GrowPanel<Head: View, Panel: View>: View {
    @Binding var open: Bool
    let radius: CGFloat
    @ViewBuilder let head: Head
    @ViewBuilder let panel: Panel
    @Environment(\.headerGivesWay) private var givesWay
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active
    @Environment(ModalHost.self) private var host: ModalHost?
    @State private var token = UUID()
    @State private var frame = Frame()
    @AccessibilityFocusState private var headFocused: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius)
        GrownWidth(open: open) {
            VStack(spacing: 0) {
                head
                    .environment(\.headerGrown, true)
                    .dynamicTypeSize(...FloatingHeaderLayout.largestType)
                    .opacity(givesWay ? 0 : 1)
                    .accessibilityFocused($headFocused)
                if open { panel.transition(.opacity.combined(with: .offset(y: -6))) }
            }
            .frame(maxWidth: open ? .infinity : nil)
            .clipShape(shape)
            // 玻璃挂在内容本身上（不挂在一块空的背景上）：页顶那一排的玻璃容器把容器里挂在空背景上的玻璃合成到字上面
            .glass(in: shape)
            .opacity(givesWay && !open ? 0 : 1)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(open ? .isModal : [])
            .accessibilityAction(.escape) { $open.grow(to: false, reduceMotion: reduceMotion) }
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: {
                frame.rect = $0
                host?.reshape(token, hole: $0)
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
        .ignoresSafeArea(.keyboard)
        .sensoryFeedback(.impact(weight: .light), trigger: open)
        .preference(key: Grown.self, value: open)
        .onChange(of: open, initial: true) { _, open in
            guard open else {
                host?.uncover(token)
                headFocused = true
                return
            }
            host?.cover(ModalHost.Modal(token: token, close: ClosePanel { [$open, reduceMotion] in $open.grow(to: false, reduceMotion: reduceMotion) }, inPage: true), hole: frame.rect)
        }
        .onDisappear {
            open = false
            host?.uncover(token)
        }
        .onChange(of: active) { if !active { open = false } }
    }
}

private final class Frame {
    var rect: CGRect?
}

private struct GrownWidth: Layout {
    let open: Bool
    static let widest: CGFloat = 440

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews[0].sizeThatFits(offer(proposal))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews[0].place(at: CGPoint(x: bounds.midX, y: bounds.minY), anchor: .top, proposal: offer(proposal))
    }

    private func offer(_ proposal: ProposedViewSize) -> ProposedViewSize {
        guard open, let full = proposal.width, full - FloatingHeaderLayout.slot * 2 >= Self.widest else { return proposal }
        return ProposedViewSize(width: Self.widest, height: proposal.height)
    }
}

extension Binding<Bool> {
    func grow(to value: Bool? = nil, reduceMotion: Bool) {
        let next = value ?? !wrappedValue
        guard next != wrappedValue else { return }
        withAnimation(Motion.spatial(Motion.nudge, reduceMotion: reduceMotion)) { wrappedValue = next }
    }
}
#endif
