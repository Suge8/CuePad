#if os(iOS)
import SwiftUI

extension View {
    /// 推入页的顶栏（全 App 只此一种）：左边系统的圆形返回，中间一块玻璃（标题，下面一行要紧信息），右边最多一个圆钮
    /// （多个操作时调用方给一个"⋯"`Menu`）。顶上不做滚动模糊，内容从玻璃之间透出来。
    /// `collapsed` 时中间那块收成右上角一颗小胶囊：标题，后面跟 `collapsedDetail`（如会话的状态点与计时），点它调用 `expand`。
    /// 标题同时是读屏、返回菜单与多任务切换器里的名字。
    func floatingHeader<Detail: View, CollapsedDetail: View, Trailing: View>(
        _ title: String, collapsed: Bool = false, expand: (() -> Void)? = nil,
        @ViewBuilder detail: () -> Detail, @ViewBuilder collapsedDetail: () -> CollapsedDetail,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(
            title: title, collapsed: collapsed, expand: expand, detail: detail(), collapsedDetail: collapsedDetail(), trailing: trailing()))
    }

    /// 收起时小胶囊只写标题。
    func floatingHeader<Detail: View, Trailing: View>(
        _ title: String, collapsed: Bool = false, expand: (() -> Void)? = nil,
        @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        floatingHeader(title, collapsed: collapsed, expand: expand, detail: detail, collapsedDetail: { EmptyView() }, trailing: trailing)
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

private struct FloatingHeader<Detail: View, CollapsedDetail: View, Trailing: View>: ViewModifier {
    let title: String
    let collapsed: Bool
    let expand: (() -> Void)?
    let detail: Detail
    let collapsedDetail: CollapsedDetail
    let trailing: Trailing
    @Environment(\.palette) private var palette

    /// 与系统返回钮、工具栏圆钮同高。
    static var height: CGFloat { 44 }

    func body(content: Content) -> some View {
        content
            .scrollEdgeEffectHidden(true, for: .top)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // 中间这一项推入时就建好、一直在，标题与信息只在它里面换，收起时也只是透明（这一项不在时系统会把标题当普通文字
            // 摆回中间）：推入转场期间系统不重建工具栏项，换项要等转场结束才显示。收起后的小胶囊是收起那一刻才加的项，
            // 推入时已是收起的页第一帧就有它
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
                    .opacity(title.isEmpty || collapsed ? 0 : 1)
                    .animation(Motion.quick, value: title.isEmpty || collapsed)
                    .allowsHitTesting(!collapsed)
                    .accessibilityHidden(collapsed)
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                if collapsed {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { expand?() } label: {
                            HStack(spacing: 6) {
                                Text(title).font(.footnote.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
                                collapsedDetail
                            }
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 12)
                        }
                        .accessibilityElement(children: .combine)
                        .accessibilityHint(expand == nil ? "" : "展开顶栏")
                    }
                    // 小胶囊自成一块玻璃，不与右边的圆钮并成一条
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                if Trailing.self != EmptyView.self {
                    ToolbarItem(placement: .primaryAction) { trailing }
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
