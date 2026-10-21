#if os(iOS)
import SwiftUI

/// 从顶上一条长出面板的一块实底玻璃（Cue 页头、会话页顶栏中间那颗胶囊）：同一块玻璃长高，收着时不铺满的（`fills` 为假）同时长宽到铺满。
/// 面板的几行按长大后的位置排好、淡入并下移 6 点，玻璃还在长的那几帧里不画到玻璃外面。点面板外收起（背后的页面不压色），离开页面时收起，
/// 开合轻触感一下。开没开由调用方持有，`head` 里的按钮经 `grow` 开合（无回弹弹簧 `Motion.snappy`，减弱动态效果时直接到终态）。
struct GrowPanel<Head: View, Panel: View>: View {
    @Binding var open: Bool
    let radius: CGFloat
    /// 收着时也铺满宽（Cue 页头）；否则只占 `head` 的宽、居中。
    var fills = true
    /// 收着时整块让开（提示横幅盖在这一排上）。
    var hidden = false
    /// 玻璃离外框的距离（点面板外收起的那一层不受它限制）。
    var margin = EdgeInsets()
    /// 面板里行与行之间的空（`rowContainer`）。
    var rowGap: CGFloat = 0
    @ViewBuilder let head: Head
    @ViewBuilder let panel: Panel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        ZStack(alignment: .top) {
            if open {
                Color.clear.contentShape(.rect).ignoresSafeArea()
                    .onTapGesture { $open.grow(reduceMotion: reduceMotion) }
                    .accessibilityHidden(true)
            }
            VStack(alignment: fills ? .leading : .center, spacing: 0) {
                head
                if open { panel.transition(.opacity.combined(with: .offset(y: -6))) }
            }
            .frame(maxWidth: fills || open ? .infinity : nil, alignment: .leading)
            .clipShape(shape)
            .rowContainer(shape, gap: rowGap)
            .glass(in: shape)
            .opacity(hidden && !open ? 0 : 1)
            .padding(margin)
        }
        .frame(maxWidth: .infinity, maxHeight: open ? .infinity : nil, alignment: .top)
        .sensoryFeedback(.impact(weight: .light), trigger: open)
        .onDisappear { open = false }
    }
}

extension Binding<Bool> {
    func grow(reduceMotion: Bool) {
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { wrappedValue.toggle() }
    }
}
#endif
