#if os(iOS)
import SwiftUI

extension View {
    /// 页顶那一排（全 App 只此一种，手机与 iPad、根页与推入页同一个）：左边一颗圆钮，中间一两块玻璃，右边至多一颗圆钮
    /// （多个操作时调用方给一个"⋯"`Menu`），各是一块玻璃，玻璃之间透出内容；内容一直滚到这一排后面，栏后面不垫模糊或渐变（`Bars`）。
    /// 中间是标题与下面一行要紧信息（推入页），或调用方给的 `center`（根页：这一页的范围，Cue 页是 Cue 的名牌），不写页名大标题：
    /// 底部那一排与侧栏的选中格已经说了在哪一页。中间那几块由 `headerPiece` 或 `GrowPanel` 画，提示横幅盖在这一排上时让开。
    /// 画在哪由所在的地方定（`HeaderHost`），调用处不分：
    /// - 系统导航栏（推入的页，与 iPad 右边那一栏的根）：左边是系统的圆形返回（左缘右滑返回、长按返回菜单都是系统的）或侧栏钮，
    ///   中间与右边是导航栏里的两项。两项推入时就建好、一直在，标题与信息只在项里面换，让开也只是透明：推入转场期间系统不重建工具栏项，
    ///   换项要等转场结束才显示；中间这一项不在时系统还会把标题当普通文字摆回中间。
    /// - 页自己画（窄屏根上四页、iPad 右侧的 Cue 面板）：系统导航栏藏着，这一排随页切走（`HomePager`），左边是搜索钮（Cue 页没有）。
    /// `hidden` 时中间与右边让开（淡到透明、不可点、读屏跳过），左边一直在；占的高度不变，内容的边距不跟着变（会话页看历史时用，
    /// 见 `ChatFollow.showsHeader`）；给了 `reveal` 时让开的那一块仍接点按，点它唤出。标题同时是读屏、返回菜单与多任务切换器里的名字。
    func floatingHeader<Detail: View, Trailing: View>(
        _ title: String, hidden: Bool = false, reveal: (() -> Void)? = nil,
        @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(
            title: title, hidden: hidden, reveal: reveal, titled: true,
            center: TitleStack(title: title, detail: detail()).padding(.horizontal, 16).headerPiece().opacity(title.isEmpty ? 0 : 1),
            trailing: trailing()))
    }

    /// 根页：中间放 `center`（任务页、会话页是项目范围 `ProjectScope`，会话页再接额度环；Cue 页是它的名牌 `CueHeader`），不写标题。
    func floatingHeader<Center: View, Trailing: View>(
        _ title: String, @ViewBuilder center: () -> Center, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(title: title, hidden: false, reveal: nil, titled: false, center: center(), trailing: trailing()))
    }

    /// 要紧信息是一行字、右边一个圆钮或"⋯"菜单。`detail` 为 nil 时只写标题；要等读库才有的信息先给空串，
    /// 那一行先留着位置，读到后标题不再上移。
    func floatingHeader<Trailing: View>(_ title: String, detail: Dotted? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        floatingHeader(title, detail: { HeaderDetail(text: detail) }, trailing: trailing)
    }

    func floatingHeader(_ title: String, detail: Dotted? = nil) -> some View {
        floatingHeader(title, detail: detail) { EmptyView() }
    }

    /// 页顶那一排中间的一块（标题、项目范围、额度环）：一块写字玻璃胶囊；提示横幅盖在这一排上时让开（它比这一块矮，露一截就是玻璃叠玻璃），
    /// 在长开的面板里（`GrowPanel`）不另画玻璃，面板本身就是。
    func headerPiece() -> some View { modifier(HeaderPiece()) }
}

/// 页顶那一排画在哪（`FloatingHeader`）：系统导航栏，或页自己画。
enum HeaderHost: Equatable {
    case navigationBar
    /// 页自己画，系统导航栏藏着；`search`：左边是搜索钮。
    case page(search: Bool)
    /// iPad 右侧的 Cue 面板：自己画，提示横幅不在它上面（横幅在右边那一栏里），不用让开。
    case panel
}

extension EnvironmentValues {
    @Entry var headerHost = HeaderHost.navigationBar
    /// 提示横幅盖在页顶那一排上：中间那几块让开（`headerPiece`、`GrowPanel`）。
    @Entry var headerGivesWay = false
    /// 在长开的 `GrowPanel` 里：中间那几块不另画玻璃。
    @Entry var headerGrown = false
    /// 这一页的名字此刻在别处写着（窄屏底部那一排、iPad 侧栏的选中格）：页顶那一排不再写标题，同一屏不重复。
    @Entry var pageNamedElsewhere = false
}

enum FloatingHeaderLayout {
    /// 与系统返回钮、工具栏圆钮同高；顶部的提示横幅与它同高、落在两侧圆钮之间（`NoticeBanner`）。
    static let height: CGFloat = 44
}

private struct FloatingHeader<Center: View, Trailing: View>: ViewModifier {
    let title: String
    let hidden: Bool
    let reveal: (() -> Void)?
    /// 中间是标题：这一页的名字在别处写着时（`pageNamedElsewhere`）不写，只留两边的圆钮。
    let titled: Bool
    let center: Center
    let trailing: Trailing
    @Environment(\.headerHost) private var host
    @Environment(\.pageNamedElsewhere) private var namedElsewhere
    @Environment(Workspace.self) private var workspace

    func body(content: Content) -> some View {
        Group {
            switch host {
            case .page, .panel:
                // 内容让到这一排下面再隔 `Bars.contentGap`；这一排排在让出之前的安全区里，贴着状态栏下沿，同导航栏里的圆钮
                content
                    .safeAreaPadding(.top, FloatingHeaderLayout.height + Bars.contentGap)
                    .overlay(alignment: .top) {
                        PageBar(search: host == .page(search: true), trailing: trailing) { if showsMiddle { middle } }
                    }
            case .navigationBar:
                content
                    // 标题只在中间那块玻璃里：不在 `RouteView` 里的页（任务正文的编辑 sheet）也不能让系统在下面再排一个大标题
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        // 不写标题时也留着这一项（空的）：中间这一项不在时系统会把标题当普通文字摆回中间
                        ToolbarItem(placement: .principal) { if showsMiddle { middle } else { Color.clear.frame(width: 1, height: 1) } }
                            // 玻璃自己画，不再套一层系统的玻璃底（玻璃不叠玻璃）
                            .sharedBackgroundVisibility(.hidden)
                        if Trailing.self != EmptyView.self {
                            ToolbarItem(placement: .primaryAction) { yielding(trailing) }
                                // 圆钮的玻璃是系统给的：让开时连它一起不画
                                .sharedBackgroundVisibility(hidden ? .hidden : .automatic)
                        }
                    }
            }
        }
        .navigationTitle(title)
        .environment(\.headerGivesWay, host != .panel && workspace.notice != nil)
        .animation(NoticeBanner.giveWay(workspace.notice), value: workspace.notice != nil)
    }

    private var showsMiddle: Bool { !(titled && namedElsewhere) }

    private var middle: some View {
        HStack(spacing: 8) { center }
            .modifier(Yield(hidden: hidden))
            .background {
                if hidden, let reveal { Color.clear.contentShape(.capsule).onTapGesture(perform: reveal).accessibilityHidden(true) }
            }
    }

    private func yielding(_ view: some View) -> some View { view.modifier(Yield(hidden: hidden)) }
}

/// 让开：淡到透明、不可点、读屏跳过。
private struct Yield: ViewModifier {
    let hidden: Bool

    func body(content: Content) -> some View {
        content
            .opacity(hidden ? 0 : 1)
            .animation(HandOff.quick, value: hidden)
            .allowsHitTesting(!hidden)
            .accessibilityHidden(hidden)
    }
}

/// 页自己画的那一排：左边搜索钮（`search`），右边这一页的那一个操作，两颗玻璃圆钮，位置同导航栏里的返回钮与圆钮；
/// 中间那几块盖在两颗圆钮之上一层：从中间长出的面板（`GrowPanel`）铺满这一排往下长。
private struct PageBar<Middle: View, Trailing: View>: View {
    let search: Bool
    let trailing: Trailing
    @ViewBuilder let middle: Middle
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
            middle
        }
        .padding(.horizontal, 16)
    }
}

private struct HeaderPiece: ViewModifier {
    @Environment(\.headerGivesWay) private var givesWay
    @Environment(\.headerGrown) private var grown

    func body(content: Content) -> some View {
        Group {
            if grown { content } else { content.glass(in: .capsule) }
        }
        .frame(height: FloatingHeaderLayout.height)
        .contentShape(.capsule)
        .opacity(givesWay && !grown ? 0 : 1)
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
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
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
