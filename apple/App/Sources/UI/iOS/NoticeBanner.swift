#if os(iOS)
import SwiftUI

/// 每个窗口只显示一条短提示（`NoticeCapsule`，停多久、摆在哪见 `Workspace+Notice`）。会话条不在时在这里：暂时盖在顶栏中间（盖住的让开，两侧操作仍可用）；
/// iPad 面板也共用窗口的提示。窄屏盖在整个窗口上，宽屏在右边那一栏里居中（不盖侧栏顶上的圆钮）。会话条在时提示在它底部（`WideRail`），这里只剩下面那几件不论摆在哪都要做的事。
/// 提示与会话前台提示的变化只在这里读：根视图读了的话，每弹一条、消一条整个窗口（分栏的每一栏）都要重算一遍。
struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace

    private static let sideClearance = FloatingHeaderLayout.margin + FloatingHeaderLayout.slot
    /// iPad 上也保持胶囊，不铺满整个窗口。
    private static let maxWidth: CGFloat = 440

    /// 被盖住的名牌、页头给横幅让开：立刻淡出；横幅收走后等它离场再淡回来，两块玻璃不叠着、不交叉淡。
    static func giveWay(_ covered: Bool) -> Animation {
        covered ? Motion.fade : Motion.fade.delay(Motion.Fade.settle)
    }

    var body: some View {
        let field = workspace.layout == .narrow && (workspace.top == .shelf || workspace.top == .progress)
        NoticeSlot(place: .head(fills: true))
            .frame(maxWidth: field ? .infinity : Self.maxWidth)
            .frame(maxWidth: .infinity)
            .padding(.leading, field ? FloatingHeaderLayout.margin : Self.sideClearance)
            .padding(.trailing, Self.sideClearance)
            .animation(Motion.fade, value: field)
            // iPad 窄窗口：按窗口给的角落让开左上的窗口钮，不盖住它
            .containerCornerOffset(.horizontal, sizeToFit: true)
            .sensoryFeedback(trigger: workspace.notice) { _, notice in
                guard let notice else { return nil }
                return notice.isError ? .error : .success
            }
            // 前台时会话"等你确认"、"做完了"的提示：开着那个会话时不弹；后台走系统推送
            .onChange(of: workspace.services.sessionAlert) { _, alert in
                guard !DebugHooks.preset.quietAlerts, let alert, workspace.showsAlert(about: alert.session) else { return }
                workspace.say(alert.text, status: alert.status, link: .session(alert.session), sound: Sound(alert.kind.tone))
            }
            // 手机通话异常结束、有话没交给 Cue：不论在哪一页都在这里说
            .background { PhoneVoiceEndings() }
            // 弹出后才进了那个会话（或 Agent 列表）：当场撤下
            .onChange(of: workspace.notice.map(workspace.keeps)) { _, keeps in if keeps == false { workspace.notice = nil } }
    }
}
#endif
