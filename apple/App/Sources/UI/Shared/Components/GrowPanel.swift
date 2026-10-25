#if os(iOS)
import SwiftUI

/// 从页顶那一排长出面板的一块实底玻璃（Cue 的名牌、进展页的分段与额度环）：收着时只占 `head` 的宽、居中，同一块玻璃长高、长宽到铺满。
/// `head` 里的几块不另画玻璃（`headerGrown`）；`head` 可以跟着开合换排法（Cue 的名牌长成名片），在同一块玻璃里一起长。
/// 面板的几行按长大后的位置排好、淡入并下移 6 点，玻璃还在长的那几帧里不画到玻璃外面。点面板外只收起、不开（背后的页面不压色），离开页面时收起，
/// 开合轻触感一下；提示横幅盖在这一排上时收着的整块让开，开着的只让开 `head`。开没开由调用方持有，`head` 里的按钮经 `grow` 开合
/// （无回弹弹簧 `Motion.snappy`，减弱动态效果时直接到终态）。
/// 里面的高度只在开合时变：长大的动画里挨一下不带动画的改高，整块玻璃就有几帧不画。面板能长到的高不让键盘：键盘起落时里面不跟着重排
/// （Cue 的名牌开面板前先收起键盘，按的是收完的高）。
/// 放在系统导航栏里时（iPad，`HeaderHost.navigationBar`）长不出来：栏里的项按栏高摆、画不到栏外，面板改由系统的弹出框从这一块弹出。
struct GrowPanel<Head: View, Panel: View>: View {
    @Binding var open: Bool
    let radius: CGFloat
    @ViewBuilder let head: Head
    @ViewBuilder let panel: Panel
    @Environment(\.headerGivesWay) private var givesWay
    @Environment(\.headerHost) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active

    /// 系统弹出框里面板的宽。
    private static var popoverWidth: CGFloat { 380 }

    var body: some View {
        if host == .navigationBar { inBar } else { growing }
    }

    private var inBar: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return head
            .environment(\.headerGrown, true)
            .dynamicTypeSize(...FloatingHeaderLayout.largestType)
            .background { Color.clear.glass(in: shape) }
            .opacity(givesWay ? 0 : 1)
            .popover(isPresented: $open) {
                panel.padding(.top, 12).frame(width: Self.popoverWidth).presentationCompactAdaptation(.popover)
            }
            .sensoryFeedback(.impact(weight: .light), trigger: open)
    }

    private var growing: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return ZStack(alignment: .top) {
            if open {
                Color.clear.contentShape(.rect).ignoresSafeArea()
                    .onTapGesture { $open.grow(to: false, reduceMotion: reduceMotion) }
                    .transition(.identity)
                    .accessibilityHidden(true)
            }
            VStack(spacing: 0) {
                head
                    .environment(\.headerGrown, true)
                    .dynamicTypeSize(...FloatingHeaderLayout.largestType)
                    .opacity(givesWay ? 0 : 1)
                if open { panel.transition(.opacity.combined(with: .offset(y: -6))) }
            }
            .frame(maxWidth: open ? .infinity : nil)
            .clipShape(shape)
            .background { Color.clear.glass(in: shape) }
            .opacity(givesWay && !open ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: open ? .infinity : nil, alignment: .top)
        .ignoresSafeArea(.keyboard)
        .sensoryFeedback(.impact(weight: .light), trigger: open)
        .onDisappear { open = false }
        // 窄屏滑走了这一页（它还留着）也收起
        .onChange(of: active) { if !active { open = false } }
    }
}

extension Binding<Bool> {
    /// 开合面板：给了 `to` 就到那一态（已经是就不动），不给就换一态。
    func grow(to value: Bool? = nil, reduceMotion: Bool) {
        let next = value ?? !wrappedValue
        guard next != wrappedValue else { return }
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { wrappedValue = next }
    }
}
#endif
