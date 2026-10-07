#if os(iOS)
import SwiftUI

extension View {
    /// 推入页的顶栏（全 App 只此一种）：左边系统的圆形返回，中间一块玻璃（标题，下面一行要紧信息），右边最多一个圆钮
    /// （多个操作时调用方给一个"⋯"`Menu`）。顶上不做滚动模糊，内容从玻璃之间透出来。
    /// `hidden` 时返回钮、中间那块与右边的圆钮都让开（淡到透明、不可点、读屏跳过），导航栏本身留着：
    /// 顶栏占的高度与安全区不变，内容的边距不跟着变（会话页看历史时用，见 `ChatFollow.showsHeader`）。
    /// 标题同时是读屏、返回菜单与多任务切换器里的名字。
    func floatingHeader<Detail: View, Trailing: View>(
        _ title: String, hidden: Bool = false, @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(title: title, hidden: hidden, detail: detail(), trailing: trailing()))
    }

    /// 要紧信息是一行字、右边一个圆钮或"⋯"菜单。`detail` 为 nil 时只写标题；要等读库才有的信息先给空串，
    /// 那一行先留着位置，读到后标题不再上移。
    func floatingHeader<Trailing: View>(_ title: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        floatingHeader(title, detail: { HeaderDetail(text: detail) }, trailing: trailing)
    }

    /// 没有操作的页。
    func floatingHeader(_ title: String, detail: String? = nil) -> some View {
        floatingHeader(title, detail: detail) { EmptyView() }
    }
}

private struct FloatingHeader<Detail: View, Trailing: View>: ViewModifier {
    let title: String
    let hidden: Bool
    let detail: Detail
    let trailing: Trailing
    @Environment(\.palette) private var palette

    /// 与系统返回钮、工具栏圆钮同高。
    static var height: CGFloat { 44 }

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(hidden)
            // 两项推入时就建好、一直在，标题与信息只在项里面换，让开也只是透明：推入转场期间系统不重建工具栏项，
            // 换项要等转场结束才显示；中间这一项不在时系统还会把标题当普通文字摆回中间
            .toolbar {
                // 标题要等读库才有的页（卡片纸页）先透明，读到后淡入
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                        detail
                    }
                    .padding(.horizontal, 16)
                    .frame(height: Self.height)
                    .glass(in: .capsule)
                    .opacity(title.isEmpty || hidden ? 0 : 1)
                    .animation(Motion.quick, value: title.isEmpty || hidden)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                if Trailing.self != EmptyView.self {
                    ToolbarItem(placement: .primaryAction) {
                        trailing
                            .opacity(hidden ? 0 : 1)
                            .animation(Motion.quick, value: hidden)
                            .allowsHitTesting(!hidden)
                            .accessibilityHidden(hidden)
                    }
                    // 圆钮的玻璃是系统给的：让开时连它一起不画
                    .sharedBackgroundVisibility(hidden ? .hidden : .automatic)
                }
            }
    }
}

/// 顶栏玻璃里标题下的一行：小字、次要色、一行截断；nil 不占行，空串留着一行的位置。
private struct HeaderDetail: View {
    let text: String?
    @Environment(\.palette) private var palette

    var body: some View {
        if let text {
            Text(text.isEmpty ? " " : text).font(.caption.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
                .contentTransition(.numericText())
                .animation(Motion.quick, value: text)
        }
    }
}
#endif
