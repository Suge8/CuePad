#if os(iOS)
import SwiftUI

extension View {
    /// 推入页的顶栏（全 App 只此一种）：左边系统的圆形返回，中间一块玻璃（标题，下面一行要紧信息），右边最多一个圆钮
    /// （多个操作时调用方给一个"⋯"`Menu`）。内容一直滚到状态栏与顶栏下面（沉浸式），栏后面不垫模糊或渐变，玻璃本身就是遮挡（见 `RouteView`）。
    /// `hidden` 时中间那块与右边的圆钮让开（淡到透明、不可点、读屏跳过），返回钮一直在——随时看得到怎么回去，
    /// 左缘右滑返回照常是系统的；导航栏本身留着：顶栏占的高度与安全区不变，内容的边距不跟着变（会话页看历史时用，
    /// 见 `ChatFollow.showsHeader`）；给了 `reveal` 时让开的那一块仍接点按，点它唤出。
    /// 标题同时是读屏、返回菜单与多任务切换器里的名字。
    /// 窄屏导航栈的根（任务、会话、项目三页，`largeTitle`）不是推入页：标题是系统大标题，那一行要紧信息不写，右边的圆钮照旧。
    /// `explanation`：点中间那块玻璃弹出的一句说明（会话需要 /reload 时怎么接上）；没有时点它什么也不做。
    func floatingHeader<Detail: View, Trailing: View>(
        _ title: String, hidden: Bool = false, reveal: (() -> Void)? = nil, explanation: String? = nil,
        @ViewBuilder detail: () -> Detail, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        let label = TitleStack(title: title, detail: detail()).padding(.horizontal, 16)
        return modifier(FloatingHeader(
            title: title, hidden: hidden, reveal: reveal, explanation: explanation, label: label, trailing: trailing()))
    }

    /// 玻璃里不是"标题与一行信息"的页（Cue 页：头像接名字与状态，`CueTitle`）：`label` 是玻璃里的全部内容，边距自己给；`title` 只给读屏与系统。
    func floatingHeader<Label: View, Trailing: View>(
        _ title: String, @ViewBuilder label: () -> Label, @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        modifier(FloatingHeader(title: title, hidden: false, reveal: nil, explanation: nil, label: label(), trailing: trailing()))
    }

    /// 要紧信息是一行字、右边一个圆钮或"⋯"菜单。`detail` 为 nil 时只写标题；要等读库才有的信息先给空串，
    /// 那一行先留着位置，读到后标题不再上移。
    func floatingHeader<Trailing: View>(_ title: String, detail: Dotted? = nil, @ViewBuilder trailing: () -> Trailing) -> some View {
        floatingHeader(title, detail: { HeaderDetail(text: detail) }, trailing: trailing)
    }

    /// 没有操作的页。
    func floatingHeader(_ title: String, detail: Dotted? = nil) -> some View {
        floatingHeader(title, detail: detail) { EmptyView() }
    }
}

extension EnvironmentValues {
    /// 这一页是窄屏导航栈的根（`RouteView.home`）：顶栏用系统大标题。
    @Entry var largeTitle = false
}

enum FloatingHeaderLayout {
    /// 与系统返回钮、工具栏圆钮同高；顶部的提示横幅与它同高、落在两侧圆钮之间（`NoticeBanner`）。
    static let height: CGFloat = 44
}

private struct FloatingHeader<Label: View, Trailing: View>: ViewModifier {
    let title: String
    let hidden: Bool
    let reveal: (() -> Void)?
    let explanation: String?
    let label: Label
    let trailing: Trailing
    @Environment(\.palette) private var palette
    @Environment(\.largeTitle) private var largeTitle

    func body(content: Content) -> some View {
        if largeTitle {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.large)
                .toolbar {
                    if Trailing.self != EmptyView.self { ToolbarItem(placement: .primaryAction) { trailing } }
                }
        } else {
            floating(content)
        }
    }

    private func floating(_ content: Content) -> some View {
        content
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            // 两项推入时就建好、一直在，标题与信息只在项里面换，让开也只是透明：推入转场期间系统不重建工具栏项，
            // 换项要等转场结束才显示；中间这一项不在时系统还会把标题当普通文字摆回中间
            .toolbar {
                // 标题要等读库才有的页（卡片纸页）先透明，读到后淡入
                ToolbarItem(placement: .principal) {
                    HeaderTitle(explanation: explanation) { label }
                    .opacity(title.isEmpty || hidden ? 0 : 1)
                    .animation(Motion.quick, value: title.isEmpty || hidden)
                    .allowsHitTesting(!hidden)
                    .accessibilityHidden(hidden)
                    .background {
                        if hidden, let reveal {
                            Color.clear.contentShape(.capsule).onTapGesture(perform: reveal).accessibilityHidden(true)
                        }
                    }
                }
                // 玻璃自己画（实底，`GlassInk.solid`），不再套一层系统的玻璃底（玻璃不叠玻璃）
                .sharedBackgroundVisibility(.hidden)
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

/// 顶栏中间那块玻璃（多是标题与一行要紧信息）。有说明时整块是一颗按钮，点它弹出说明（状态自己持有：顶栏项推入时就建好，
/// 改外面的状态不一定重建它）；没有说明时只是标题。
private struct HeaderTitle<Label: View>: View {
    let explanation: String?
    @ViewBuilder let label: Label
    @Environment(Workspace.self) private var workspace
    @State private var explaining = false

    var body: some View {
        Group {
            if explanation != nil {
                Button { explaining = true } label: { plate }.buttonStyle(.plain)
            } else {
                plate
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(explanation == nil ? .isHeader : [.isHeader, .isButton])
        .accessibilityHint(explanation == nil ? "" : "看说明")
        .explanationPopover(explanation, isPresented: $explaining)
        .task(id: explanation) { if explanation != nil, DebugHooks.preset.explain { explaining = true } }
    }

    /// 提示横幅盖在这一格上时让开（它比名牌矮，露一截上沿就是玻璃叠玻璃）。
    private var plate: some View {
        label
            .frame(height: FloatingHeaderLayout.height)
            .glass(in: .capsule)
            .contentShape(.capsule)
            .opacity(workspace.notice == nil ? 1 : 0)
            .animation(NoticeBanner.giveWay(workspace.notice), value: workspace.notice == nil)
    }
}

/// 标题，下面一行要紧信息。
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
                .animation(Motion.quick, value: text)
        }
    }
}
#endif
