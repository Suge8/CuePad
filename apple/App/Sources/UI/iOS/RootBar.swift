#if os(iOS)
import SwiftUI

/// 宽屏上自带顶上一排的页（搜索页）的那一排：中间是这一页的主体（搜索框），右边是本页唯一的新建（没有就空着）。
/// 不放搜索框以外的状态与"⋯"：顶栏的规则见 docs/ui.md。iPhone 上搜索框在导航栏中间（`SearchScreen`），Cue 页头在导航栏那一排里（`inNavigationBarRow`）。
struct RootBar<Center: View, Trailing: View>: View {
    @ViewBuilder let center: Center
    @ViewBuilder let trailing: Trailing

    var body: some View {
        HStack(spacing: 8) {
            if Center.self == EmptyView.self { Spacer(minLength: 0) } else { center.frame(maxWidth: .infinity) }
            trailing
        }
        .buttonStyle(ControlButtonStyle(kind: .circular)).labelStyle(.iconOnly)
        .padding(.horizontal, 16).padding(.top, 4).padding(.bottom, 8)
        // iPad 窗口的关闭、缩小、排列钮在左上角：这一排是自绘的、不在导航栏里，系统不替它让位，按窗口给的角落整排让出来
        // （连同页边距一起让，窗口钮就当是屏幕边。顶上的提示横幅按同一处让，见 `NoticeBanner`）
        .containerCornerOffset(.horizontal, sizeToFit: true)
    }
}

extension RootBar where Trailing == EmptyView {
    init(@ViewBuilder center: () -> Center) { self.init(center: center) { EmptyView() } }
}

extension View {
    /// iPhone 上自带顶上一排的页（Cue 页头）留着导航栏：左边是系统的返回，左缘右滑回到列表也要导航栏在
    /// （藏起导航栏的页系统不给滑回）。这一排挪进导航栏那一排、与返回钮竖向居中，左边让出返回钮。
    /// 导航栏盖在页面上、接走它那一排里的点按：`tap` 是点在这一排上要做的（导航栏中间那一格里铺一层透明的点按区转过来）。
    func inNavigationBarRow(_ active: Bool, height: CGFloat, tap: @escaping () -> Void) -> some View {
        modifier(NavigationBarRow(active: active, height: height, tap: tap))
    }
}

/// 导航栏那一排的高 = 这一排原本的上沿（导航栏下沿）减状态栏下沿。挪是位移（画面与点按区一起挪），量的是位移外面不动的布局位置；
/// 布局上从底下收回同样的高，不空出一排。
private struct NavigationBarRow: ViewModifier {
    let active: Bool
    let height: CGFloat
    let tap: () -> Void
    @Environment(\.statusBarBottom) private var statusBar
    @State private var frame: CGRect = .zero

    private static let back = ControlMetrics.height + 8

    func body(content: Content) -> some View {
        let row = max(0, frame.minY - statusBar)
        let lift = active ? row - (row - height) / 2 : 0
        content
            .padding(.leading, active ? Self.back : 0)
            .offset(y: -lift)
            .padding(.bottom, -lift)
            // 量在位移外面：位移里面量到的全局位置跟着位移变，量与挪成环
            .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame = $0 }
            .toolbar {
                if active {
                    // 导航栏中间那一格不会自己铺满：按这一排的宽给定宽度，系统把它摆在返回钮右边
                    ToolbarItem(placement: .principal) {
                        Color.clear.contentShape(.rect).onTapGesture(perform: tap)
                            .frame(width: max(0, frame.width - Self.back), height: height)
                            .accessibilityHidden(true)
                    }
                    .sharedBackgroundVisibility(.hidden)
                }
            }
    }
}

/// 搜索框：玻璃胶囊（搜索页顶上）。在输入或有字时右端一个叉：清空并收起键盘。
struct SearchCapsule: View {
    static let height: CGFloat = ControlMetrics.height
    let prompt: String
    @Binding var query: String
    let focus: FocusState<Bool>.Binding
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(palette.ink3).accessibilityHidden(true)
            TextField(prompt, text: $query).submitLabel(.search).focused(focus).accessibilityLabel("搜索")
            if !query.isEmpty || focus.wrappedValue {
                Button("清除", systemImage: "xmark.circle.fill") {
                    query = ""
                    focus.wrappedValue = false
                }
                .labelStyle(.iconOnly).buttonStyle(ControlButtonStyle(kind: .quiet, compact: true))
            }
        }
        .padding(.horizontal, 14).frame(maxWidth: .infinity, minHeight: Self.height)
        .glass(in: .capsule)
    }
}
#endif
