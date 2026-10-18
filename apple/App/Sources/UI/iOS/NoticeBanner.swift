#if os(iOS)
import SwiftUI

/// 每个窗口只显示一条短提示，沿用 `Workspace` 的消退计时。暂时盖住顶栏中间的名牌或搜索框，
/// 两侧操作仍可用；不在 Cue 对话上另占一排，iPad 面板也共用窗口的提示。
/// 提示与会话前台提示的变化只在这里读：根视图读了的话，每弹一条、消一条整个窗口（分栏的每一栏）都要重算一遍。
struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 两侧让出的宽度：页边距、一颗圆钮与它和中间那块的间距，返回钮与右边的圆钮不被盖住。
    private static let sideClearance: CGFloat = 16 + FloatingHeaderLayout.height + 8
    /// 顶上那一排离上安全区（状态栏下沿）的距离，与 `RootBar` 同。
    private static let rowTop: CGFloat = 4
    /// iPad 上也保持胶囊，不铺满整个窗口。
    private static let maxWidth: CGFloat = 440

    var body: some View {
        ZStack {
            if let notice = workspace.notice {
                NoticeCapsule(notice: notice)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .id(notice.id)
            }
        }
        .frame(maxWidth: Self.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, Self.sideClearance)
        .padding(.top, Self.rowTop)
        // iPad 窄窗口：顶上那一排整排让开左上的窗口钮（`RootBar`），横幅在同一排里，按同一个窗口角让，不盖住被挪过去的圆钮
        .containerCornerOffset(.horizontal, sizeToFit: true)
        .animation(Motion.quick, value: workspace.notice)
        .sensoryFeedback(trigger: workspace.notice) { _, notice in
            guard let notice else { return nil }
            return notice.isError ? .error : .success
        }
        .onChange(of: workspace.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.text.spoken).post() }
        }
        // 前台时会话"等你确认"、"做完了"的提示：正看着那个会话或 Agent 列表时不弹；后台走系统推送
        .onChange(of: workspace.services.sessionAlert) { _, alert in
            guard let alert, navigation.showsAlert(about: alert.session) else { return }
            workspace.say(alert.text, status: alert.status, link: .session(alert.session), duration: .seconds(5))
        }
        // 弹出后才进了那个会话（或 Agent 列表）：当场撤下
        .onChange(of: workspace.notice.map(navigation.keeps)) { _, keeps in if keeps == false { workspace.notice = nil } }
    }
}

/// 一条提示本身：一块实底玻璃胶囊，带去处的点它过去，右边可有一个动作（撤销、归档）。
private struct NoticeCapsule: View {
    let notice: Workspace.Notice
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 0) {
            Button { if let link = notice.link { workspace.notice = nil; navigation.show(link) } } label: {
                HStack(spacing: 6) {
                    Label { Text(notice.text) } icon: {
                        if let status = notice.status { PiStateGlyph(status: status) }
                        else { Image(notice.isError ? .failure : .done) }
                    }
                    if notice.link != nil {
                        Image(.forward).font(.caption.weight(.semibold)).foregroundStyle(palette.ink3)
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
                .fontWeight(.semibold).foregroundStyle(palette.ink)
                .padding(.trailing, 16).padding(.leading, 8).frame(minHeight: 44)
                .contentShape(.rect)
            }
        }
        .font(.subheadline.weight(.medium)).lineLimit(1)
        .frame(maxWidth: .infinity, minHeight: FloatingHeaderLayout.height)
        // 盖住的名牌、搜索框与正文不能透出来叠字。
        .glass(in: .capsule, interactive: notice.link != nil || notice.action != nil)
        .shadow(color: palette.shadow, radius: 12, y: 4)
        .accessibilityHint(notice.link == nil ? "" : "去那里看看")
        .accessibilityAddTraits(.updatesFrequently)
    }
}
#endif
