#if os(iOS)
import SwiftUI

extension View {
    /// 推入页的顶栏（全 App 只此一种）：左边系统的圆形返回，中间一块玻璃（标题，下面一行要紧信息），右边最多一个圆钮
    /// （多个操作时调用方给一个"⋯"`Menu`）。内容一直滚到顶栏下面（沉浸式，状态栏那一条除外，见 `Bars`），栏后面不垫模糊或渐变，玻璃本身就是遮挡。
    /// `hidden` 时中间那块与右边的圆钮让开（淡到透明、不可点、读屏跳过），返回钮一直在——随时看得到怎么回去，
    /// 左缘右滑返回照常是系统的；导航栏本身留着：顶栏占的高度与安全区不变，内容的边距不跟着变（会话页看历史时用，
    /// 见 `ChatFollow.showsHeader`）；给了 `reveal` 时让开的那一块仍接点按，点它唤出。
    /// 标题同时是读屏、返回菜单与多任务切换器里的名字（窄屏导航栈的根也照样交给系统）。
    /// 窄屏导航栈的根（任务、会话、项目三页，`homePage`）不是推入页：顶上那一排是页自己画的（`HomeBar`：左边搜索、中间 `center`、右边这个圆钮），
    /// 系统导航栏藏起，切页时整排随页滑（`HomePager`）；不写标题也不写那一行要紧信息——底部那一排的选中格已经说了在哪一页，组标题写着计数。
    func floatingHeader<Detail: View, Trailing: View>(
        _ title: String, hidden: Bool = false, reveal: (() -> Void)? = nil,
        @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let label = TitleStack(title: title, detail: detail()).padding(.horizontal, 16)
        return modifier(FloatingHeader(
            title: title, hidden: hidden, reveal: reveal, label: label, center: EmptyView(), trailing: trailing()))
    }

    /// 任务页、会话页的根：顶上那一排中间放 `center`（项目范围 `ProjectScope`，会话页再接额度环），不写标题。
    /// 宽屏（iPad 侧栏旁）不是窄屏的根：导航栏里只有右边的圆钮，`center` 浮在内容顶上居中，同 Cue 页头（`CueHeader`）。
    func floatingHeader<Center: View, Trailing: View>(
        _ title: String, @ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(
            title: title, hidden: false, reveal: nil, label: EmptyView(), center: center(), trailing: trailing()))
    }

    /// 要紧信息是一行字、右边一个圆钮或"⋯"菜单。`detail` 为 nil 时只写标题；要等读库才有的信息先给空串，
    /// 那一行先留着位置，读到后标题不再上移。
    func floatingHeader<Trailing: View>(_ title: String, detail: Dotted? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        floatingHeader(title, detail: { HeaderDetail(text: detail) }, trailing: trailing)
    }

    func floatingHeader(_ title: String, detail: Dotted? = nil) -> some View {
        floatingHeader(title, detail: detail) { EmptyView() }
    }
}

extension EnvironmentValues {
    /// 这一页是窄屏导航栈的根（`HomePage`）：顶上那一排自己画、不写标题（`FloatingHeader`）。
    @Entry var homePage = false
}

enum FloatingHeaderLayout {
    /// 与系统返回钮、工具栏圆钮同高；顶部的提示横幅与它同高、落在两侧圆钮之间（`NoticeBanner`）。
    static let height: CGFloat = 44
}

private struct FloatingHeader<Label: View, Center: View, Trailing: View>: ViewModifier {
    let title: String
    let hidden: Bool
    let reveal: (() -> Void)?
    let label: Label
    let center: Center
    let trailing: Trailing
    @Environment(\.palette) private var palette
    @Environment(\.homePage) private var homePage

    func body(content: Content) -> some View {
        if homePage {
            // 内容让到这一排下面再隔 `Bars.contentGap`；这一排排在让出之前的安全区里，贴着状态栏下沿，同推入页导航栏里的圆钮
            content
                .navigationTitle(title)
                .safeAreaPadding(.top, FloatingHeaderLayout.height + Bars.contentGap)
                .overlay(alignment: .top) { HomeBar(search: true, center: center, trailing: trailing) }
        } else if Center.self != EmptyView.self {
            content
                .navigationTitle(title)
                .toolbar(removing: .title)
                .toolbar { ToolbarItem(placement: .primaryAction) { trailing } }
                .safeAreaPadding(.top, FloatingHeaderLayout.height + Bars.contentGap)
                .overlay(alignment: .top) { HomeBar(search: false, center: center, trailing: EmptyView()) }
        } else {
            floating(content)
        }
    }

    private func floating(_ content: Content) -> some View {
        content
            .navigationTitle(title)
            // 标题只在中间那块玻璃里：不在 `RouteView` 里的页（任务正文的编辑 sheet）也不能让系统在下面再排一个大标题
            .navigationBarTitleDisplayMode(.inline)
            // 两项推入时就建好、一直在，标题与信息只在项里面换，让开也只是透明：推入转场期间系统不重建工具栏项，
            // 换项要等转场结束才显示；中间这一项不在时系统还会把标题当普通文字摆回中间
            .toolbar {
                // 标题要等读库才有的页（卡片纸页）先透明，读到后淡入
                ToolbarItem(placement: .principal) {
                    HeaderTitle { label }
                    .opacity(title.isEmpty || hidden ? 0 : 1)
                    .animation(HandOff.quick, value: title.isEmpty || hidden)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
                    .background {
                        if hidden, let reveal {
                            Color.clear.contentShape(.capsule).onTapGesture(perform: reveal).accessibilityHidden(true)
                        }
                    }
                }
                // 玻璃自己画（实底，`GlassInk.solidInBar`），不再套一层系统的玻璃底（玻璃不叠玻璃）
                .sharedBackgroundVisibility(.hidden)
                if Trailing.self != EmptyView.self {
                    ToolbarItem(placement: .primaryAction) {
                        trailing
                            .opacity(hidden ? 0 : 1)
                            .animation(HandOff.quick, value: hidden)
                            .allowsHitTesting(!hidden)
                            .accessibilityHidden(hidden)
                    }
                    // 圆钮的玻璃是系统给的：让开时连它一起不画
                    .sharedBackgroundVisibility(hidden ? .hidden : .automatic)
                }
            }
    }
}

/// 窄屏三页根上的顶上那一排：左边搜索、右边这一页的那一个操作，两颗玻璃圆钮，位置同推入页导航栏里的返回钮与圆钮；
/// 中间是这一页给的 `center`（盖在两颗圆钮之上一层：会话页那颗胶囊长出的面板铺满这一排往下长；提示横幅在时让开）。
private struct HomeBar<Center: View, Trailing: View>: View {
    let search: Bool
    let center: Center
    let trailing: Trailing
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack(alignment: .top) {
            HStack {
                if search { Button("搜索", icon: .search) { workspace.openSearch() } }
                Spacer(minLength: 8)
                trailing
            }
            .labelStyle(.iconOnly)
            .buttonStyle(ControlButtonStyle(kind: .circular))
            .frame(height: FloatingHeaderLayout.height)
            // 提示横幅落在两颗圆钮之间：中间这颗让开，不叠成两层玻璃
            center
                .opacity(workspace.notice == nil ? 1 : 0)
                .animation(NoticeBanner.giveWay(workspace.notice), value: workspace.notice == nil)
        }
        .padding(.horizontal, 16)
    }
}

/// 顶栏中间那块玻璃（多是标题与一行要紧信息）。提示横幅盖在这一格上时让开（它比名牌矮，露一截上沿就是玻璃叠玻璃）。
private struct HeaderTitle<Label: View>: View {
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace

    var body: some View {
        label
            .frame(height: FloatingHeaderLayout.height)
            .glass(in: .capsule, ink: .solidInBar)
            .contentShape(.capsule)
            .opacity(workspace.notice == nil ? 1 : 0)
            .animation(NoticeBanner.giveWay(workspace.notice), value: workspace.notice == nil)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
    }
}

private struct TitleStack<Detail: View>: View {
    let title: String
    let detail: Detail
    @Environment(\.palette) private var palette

    var body: some View {
        VStack(spacing: 1) {
            Text(title).font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink).lineLimit(1)
            detail
        }
    }
}

/// 顶栏玻璃里标题下的一行：小字、次要色、一行截断；nil 不占行，空串留着一行的位置。
private struct HeaderDetail: View {
    let text: Dotted?
    @Environment(\.palette) private var palette

    var body: some View {
        if let text {
            (text.isEmpty ? Text(" ") : Text(text)).font(.caption.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
                .contentTransition(.numericText())
                .animation(HandOff.quick, value: text)
        }
    }
}
#endif
