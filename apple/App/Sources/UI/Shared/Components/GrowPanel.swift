#if os(iOS)
import SwiftUI

/// 从页顶那一排长出面板的一块实底玻璃（Cue 的名牌、会话页的额度环）：同一块玻璃长高，收着时不铺满的（`fills` 为假）同时长宽到铺满。
/// `separate`：收着时 `head` 里的几块各是各的玻璃（`headerPiece`，会话页的项目范围与额度环），长开时并成这一块。
/// 面板的几行按长大后的位置排好、淡入并下移 6 点，玻璃还在长的那几帧里不画到玻璃外面。点面板外收起（背后的页面不压色），离开页面时收起，
/// 开合轻触感一下；提示横幅盖在这一排上时收着的整块让开，开着的只让开 `head`。开没开由调用方持有，`head` 里的按钮经 `grow` 开合
/// （无回弹弹簧 `Motion.snappy`，减弱动态效果时直接到终态）。
/// 里面的高度只在开合时变：长大的动画里挨一下不带动画的改高，整块玻璃就有几帧不画（`HugHeight`）。
/// 放在系统导航栏里时（iPad，`HeaderHost.navigationBar`）长不出来：栏里的项按栏高摆、画不到栏外，面板改由系统的弹出框从这一块弹出。
struct GrowPanel<Head: View, Panel: View>: View {
    @Binding var open: Bool
    let radius: CGFloat
    /// 收着时也铺满宽（Cue 的名牌）；否则只占 `head` 的宽、居中。
    var fills = true
    var separate = false
    /// 面板里行与行之间的空（`rowContainer`）。
    var rowGap: CGFloat = 0
    @ViewBuilder let head: Head
    @ViewBuilder let panel: Panel
    @Environment(\.headerGivesWay) private var givesWay
    @Environment(\.headerHost) private var host
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.pageActive) private var active

    /// 系统弹出框里面板的宽。
    private static var popoverWidth: CGFloat { 380 }
    /// 铺满的那块（Cue 的名牌）在导航栏里的宽：栏中间那一项只给内容要的宽，名牌要定宽（`CueHeader`）。
    private static var barWidth: CGFloat { 360 }

    var body: some View {
        if host == .navigationBar { inBar } else { growing }
    }

    private var inBar: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        return head
            .frame(width: fills ? Self.barWidth : nil)
            .environment(\.headerGrown, !separate)
            .background { if !separate { Color.clear.glass(in: shape) } }
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
                    .onTapGesture { $open.grow(reduceMotion: reduceMotion) }
                    .accessibilityHidden(true)
            }
            VStack(alignment: fills ? .leading : .center, spacing: 0) {
                head
                    .environment(\.headerGrown, open || !separate)
                    .opacity(givesWay ? 0 : 1)
                if open { panel.transition(.opacity.combined(with: .offset(y: -6))) }
            }
            .frame(maxWidth: fills || open ? .infinity : nil, alignment: .leading)
            .clipShape(shape)
            .rowContainer(shape, gap: rowGap)
            .background { if open || !separate { Color.clear.glass(in: shape) } }
            .opacity(givesWay && !open ? 0 : 1)
        }
        .frame(maxWidth: .infinity, maxHeight: open ? .infinity : nil, alignment: .top)
        .sensoryFeedback(.impact(weight: .light), trigger: open)
        .onDisappear { open = false }
        // 窄屏滑走了这一页（它还留着）也收起
        .onChange(of: active) { if !active { open = false } }
    }
}

extension Binding<Bool> {
    func grow(reduceMotion: Bool) {
        withAnimation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion)) { wrappedValue.toggle() }
    }
}
#endif
