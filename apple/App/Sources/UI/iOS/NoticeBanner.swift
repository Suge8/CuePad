#if os(iOS)
import CueStore
import SwiftUI

/// 顶部的短提示：操作结果与错误。错误伴随触感。
/// 顶部的一行提示；带去处的（如随手记的落点）点它过去。
struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 横幅玻璃上垫的页面底色有多实：九成，背后的字只剩看不出的一层。
    /// 两侧让出的宽度：页边距、一颗圆钮与它和中间那块的间距，返回钮与右边的圆钮不被盖住。
    private static let sideClearance: CGFloat = 16 + FloatingHeaderLayout.height + 8
    /// 顶上那一排离上安全区（状态栏下沿）的距离，与 `SearchRow` 同。
    private static let rowTop: CGFloat = 4

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                HStack(spacing: 0) {
                    Button { if let link = notice.link { go(link) } } label: {
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
                // 背后是顶栏那一条（内容在那里已经淡完）：压住的标题或搜索框透不过来（`GlassInk.solid`）
                .glass(in: .capsule, interactive: notice.link != nil || notice.action != nil, ink: .solid)
                // 浮在内容之上：一点投影把它和底下的纸分开
                .shadow(color: .black.opacity(palette.dark ? 0.3 : 0.12), radius: 12, y: 4)
                .accessibilityHint(notice.link == nil ? "" : "去那里看看")
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                .id(notice.id)
                .accessibilityAddTraits(.updatesFrequently)
            }
        }
        // 横幅落在顶上那一排里（推入页的悬浮顶栏、标签根页的搜索与按钮行），与圆钮同高、在两侧圆钮之间：
        // 那一条里内容已经淡完，横幅不会把页面上的哪一行字切成两截；只停几秒，暂时盖住中间的标题或搜索框，返回钮与右边的圆钮露在外面
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.sideClearance)
        .padding(.top, Self.rowTop)
        // iPad 窄窗口：顶上那一排整排让开左上的窗口钮（`SearchRow`），横幅在同一排里，按同一个窗口角让，不盖住被挪过去的圆钮
        .containerCornerOffset(.horizontal, sizeToFit: true)
        .animation(Motion.quick, value: workspace.notice)
        .sensoryFeedback(trigger: workspace.notice) { _, notice in
            guard let notice else { return nil }
            return notice.isError ? .error : .success
        }
        .onChange(of: workspace.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.text.spoken).post() }
        }
    }

    private func go(_ link: Workspace.Link) {
        workspace.notice = nil
        switch link {
        case .project(let id?): navigation.show(project: id)
        case .project(nil): navigation.showInbox()
        case .session(let id): navigation.show(session: id)
        }
    }
}
#endif
