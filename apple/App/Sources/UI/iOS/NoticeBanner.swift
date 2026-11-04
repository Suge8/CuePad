#if os(iOS)
import SwiftUI

/// 每个窗口只显示一条短提示（`NoticeCapsule`，停多久见 `Workspace+Notice`），从顶边滑进。暂时盖在顶栏中间的位置（盖住的让开）：窄屏侧栏那一排（`NarrowSidebarBar`）
/// 从左页边盖到右边的 Cue 头像前，项目｜进展与这一段的工具一起让开；其余页在两侧圆钮之间居中；
/// 两侧操作仍可用；不在 Cue 对话上另占一排，iPad 面板也共用窗口的提示。窄屏盖在整个窗口上，宽屏在右边那一栏里居中（不盖侧栏顶上的圆钮）。
/// 提示与会话前台提示的变化只在这里读：根视图读了的话，每弹一条、消一条整个窗口（分栏的每一栏）都要重算一遍。
struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 两侧让出的宽度：页边距加一颗圆钮的位，返回钮与右边的圆钮不被盖住。
    private static let sideClearance = FloatingHeaderLayout.margin + FloatingHeaderLayout.slot
    /// iPad 上也保持胶囊，不铺满整个窗口。
    private static let maxWidth: CGFloat = 440

    /// 被盖住的名牌、页头给横幅让开：立刻淡出；横幅收走后等它离场再淡回来，两块玻璃不叠着、不交叉淡。
    static func giveWay(_ notice: Workspace.Notice?) -> Animation {
        notice == nil ? Motion.fade.delay(Motion.Fade.settle) : Motion.fade
    }

    var body: some View {
        let field = workspace.layout == .narrow && (workspace.top == .shelf || workspace.top == .progress)
        ZStack {
            if let notice = workspace.notice {
                NoticeCapsule(notice: notice, fills: true)
                    .elevation(.lifted)
                    .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
                    .id(notice.id)
            }
        }
        .frame(maxWidth: field ? .infinity : Self.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.leading, field ? FloatingHeaderLayout.margin : Self.sideClearance)
        .padding(.trailing, Self.sideClearance)
        .animation(Motion.fade, value: field)
        // iPad 窄窗口：按窗口给的角落让开左上的窗口钮，不盖住它
        .containerCornerOffset(.horizontal, sizeToFit: true)
        .animation(Motion.fade, value: workspace.notice)
        .sensoryFeedback(trigger: workspace.notice) { _, notice in
            guard let notice else { return nil }
            return notice.isError ? .error : .success
        }
        // 前台时会话"等你确认"、"做完了"的提示：开着那个会话时不弹；后台走系统推送
        .onChange(of: workspace.services.sessionAlert) { _, alert in
            guard !DebugHooks.preset.quietAlerts, let alert, workspace.showsAlert(about: alert.session) else { return }
            workspace.say(alert.text, status: alert.status, link: .session(alert.session))
        }
        // 弹出后才进了那个会话（或 Agent 列表）：当场撤下
        .onChange(of: workspace.notice.map(workspace.keeps)) { _, keeps in if keeps == false { workspace.notice = nil } }
    }
}
#endif
