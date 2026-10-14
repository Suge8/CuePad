#if os(iOS)
import CueStore
import SwiftUI

/// 顶部的短提示：操作结果与错误，错误伴随触感；带去处的（如随手记的落点）点它过去。
/// Cue 页在屏上时不浮在顶上，排在 Cue 页的页头下面（`CuePage`）：那一页的页头是 Cue 此刻在做什么，不能被盖住。
struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 横幅玻璃上垫的页面底色有多实：九成，背后的字只剩看不出的一层。
    /// 两侧让出的宽度：页边距、一颗圆钮与它和中间那块的间距，返回钮与右边的圆钮不被盖住。
    private static let sideClearance: CGFloat = 16 + FloatingHeaderLayout.height + 8
    /// 顶上那一排离上安全区（状态栏下沿）的距离，与 `SearchRow` 同。
    private static let rowTop: CGFloat = 4

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                NoticeCapsule(notice: notice)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(notice.id)
            }
        }
        // 横幅落在顶上那一排里（推入页的悬浮顶栏、标签根页的搜索与按钮行），与圆钮同高、在两侧圆钮之间：
        // 横幅是实底，背后滚过的正文不会透出来与它叠字；只停几秒，暂时盖住中间的标题或搜索框，返回钮与右边的圆钮露在外面
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.sideClearance)
        .padding(.top, Self.rowTop)
        // iPad 窄窗口：顶上那一排整排让开左上的窗口钮（`SearchRow`），横幅在同一排里，按同一个窗口角让，不盖住被挪过去的圆钮
        .containerCornerOffset(.horizontal, sizeToFit: true)
        .animation(Motion.quick, value: workspace.notice)
        .modifier(NoticeFeedback(notice: workspace.notice))
    }
}

/// 提示出现时的触感（错误另一种）与读屏播报：浮在顶上的横幅与 Cue 页里排在页头下面的那一条共用。
struct NoticeFeedback: ViewModifier {
    let notice: Workspace.Notice?

    func body(content: Content) -> some View {
        content
            .sensoryFeedback(trigger: notice) { _, notice in
                guard let notice else { return nil }
                return notice.isError ? .error : .success
            }
            .onChange(of: notice) { _, notice in
                if let notice { AccessibilityNotification.Announcement(notice.text.spoken).post() }
            }
    }
}

/// 一条提示本身：一块实底玻璃胶囊，带去处的点它过去，右边可有一个动作（撤销、归档）。
struct NoticeCapsule: View {
    let notice: Workspace.Notice
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Button { if let link = notice.link { workspace.notice = nil; navigation.show(link) } } label: {
                HStack(spacing: 6) {
                    Label { Text(notice.text) } icon: { Image(systemName: notice.symbol ?? (notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")) }
                    if notice.link != nil {
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
                            .accessibilityHidden(true)
                    }
                }
                .foregroundStyle(notice.isError ? AnyShapeStyle(palette.failure) : AnyShapeStyle(palette.ink))
                .padding(.leading, 16).padding(.trailing, notice.action == nil ? 16 : 8).padding(.vertical, 10)
            }
            .buttonStyle(.plain)
            .disabled(notice.link == nil)
            // 提示里的动作：撤销刚才那一下，或完成任务后的归档
            if let action = notice.action {
                Button(action.title) { workspace.run(action) }
                .fontWeight(.semibold).foregroundStyle(palette.accent)
                .padding(.trailing, 16).padding(.leading, 8).frame(minHeight: 44)
                .contentShape(.rect)
            }
        }
        .font(.subheadline.weight(.medium)).lineLimit(1)
        // 占满两侧圆钮之间那一格：整块换下中间的标题或搜索框，不在它上面露出半截
        .frame(maxWidth: .infinity, minHeight: FloatingHeaderLayout.height)
        // 背后是顶栏那一条，内容滚到这里仍清楚可见：用实一档的玻璃，压住的标题、搜索框与正文都透不过来（`GlassInk.solid`）
        .glass(in: .capsule, interactive: notice.link != nil || notice.action != nil, ink: .solid)
        // 浮在内容之上：一点投影把它和底下的纸分开
        .shadow(color: .black.opacity(palette.dark ? 0.3 : 0.12), radius: 12, y: 4)
        .accessibilityHint(notice.link == nil ? "" : "去那里看看")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
#endif
