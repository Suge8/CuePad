#if os(iOS)
import SwiftUI

/// 每个窗口只显示一条短提示，沿用 `Workspace` 的消退计时。暂时盖在顶栏中间的名牌或搜索框的位置（名牌让开），
/// 两侧操作仍可用；不在 Cue 对话上另占一排，iPad 面板也共用窗口的提示。窄屏盖在整个窗口上，宽屏在右边那一栏里居中（不盖侧栏顶上的圆钮）。
/// 永远在导航栏那一排里（与返回钮同高、同一条中线，Cue 页头那一排也是）：不往下压到内容与页头上。
/// 提示与会话前台提示的变化只在这里读：根视图读了的话，每弹一条、消一条整个窗口（分栏的每一栏）都要重算一遍。
struct NoticeBanner: View {
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 两侧让出的宽度：页边距、一颗圆钮与它和中间那块的间距，返回钮与右边的圆钮不被盖住。
    private static let sideClearance: CGFloat = 16 + FloatingHeaderLayout.height + 8
    /// iPad 上也保持胶囊，不铺满整个窗口。
    private static let maxWidth: CGFloat = 440

    /// 被盖住的名牌、页头给横幅让开：立刻淡出；横幅收走后等它离场再淡回来，两块玻璃不叠着、不交叉淡。
    static func giveWay(_ notice: Workspace.Notice?) -> Animation {
        notice == nil ? Motion.quick.delay(0.12) : Motion.quick
    }

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
        // iPad 窄窗口：按窗口给的角落让开左上的窗口钮，不盖住它
        .containerCornerOffset(.horizontal, sizeToFit: true)
        .animation(Motion.quick, value: workspace.notice)
        .sensoryFeedback(trigger: workspace.notice) { _, notice in
            guard let notice else { return nil }
            return notice.isError ? .error : .success
        }
        .onChange(of: workspace.notice) { _, notice in
            if let notice { AccessibilityNotification.Announcement(notice.text.spoken).post() }
        }
        // 前台时会话"等你确认"、"做完了"的提示：开着那个会话时不弹；后台走系统推送
        .onChange(of: workspace.services.sessionAlert) { _, alert in
            guard let alert, navigation.showsAlert(about: alert.session) else { return }
            workspace.say(alert.text, status: alert.status, link: .session(alert.session), duration: .seconds(5))
        }
        // 弹出后才进了那个会话（或 Agent 列表）：当场撤下
        .onChange(of: workspace.notice.map(navigation.keeps)) { _, keeps in if keeps == false { workspace.notice = nil } }
    }
}

/// 一条提示本身：一块实底玻璃胶囊，带去处的点它过去，右边可有一个动作（撤销、归档）。高固定是导航栏那一排（`FloatingHeaderLayout.height`）：
/// 一行放得下就一行；放不下时小一号折两行（"这是灵感，先「设为任务」再…"截在一行里正好截掉要你做的那一步）；两行也放不下（辅助字号）
/// 就一行截断——读屏照样读全文，点它照样去那里。字号至多到 xxLarge，再大一行也高过这一排。
private struct NoticeCapsule: View {
    let notice: Workspace.Notice
    @Environment(Workspace.self) private var workspace
    @Environment(Navigation.self) private var navigation
    @Environment(\.palette) private var palette

    /// 两行时上下的边距：两行小一号的字刚好放进这一排。
    private static let twoLineInset: CGFloat = 4

    var body: some View {
        ViewThatFits(in: .vertical) {
            row(font: .subheadline, lines: 2, inset: 10)
            row(font: .footnote, lines: 2, inset: Self.twoLineInset)
            row(font: .subheadline, lines: 1, inset: 10)
        }
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .frame(maxWidth: .infinity)
        .frame(height: FloatingHeaderLayout.height)
        // 盖住的名牌、搜索框与正文不能透出来叠字。
        .glass(in: .capsule, interactive: notice.link != nil || notice.action != nil)
        .shadow(color: palette.shadow, radius: 12, y: 4)
        .accessibilityHint(notice.link == nil ? "" : "去那里看看")
        .accessibilityAddTraits(.updatesFrequently)
    }

    /// 字排出来多高就多高（不截）：`ViewThatFits` 按它判断放不放得进这一排；最后一种只排一行，放不下就截断。
    private func row(font: Font, lines: Int, inset: CGFloat) -> some View {
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
                .padding(.leading, 16).padding(.trailing, notice.action == nil ? 16 : 8).padding(.vertical, inset)
            }
            .buttonStyle(.plain)
            // 没有去处时只是不接点按，不停用：停用的按钮系统整块压淡，字只剩一半深
            .allowsHitTesting(notice.link != nil)
            // 提示里的动作：撤销刚才那一下，或完成任务后的归档
            if let action = notice.action {
                Button(action.title) { workspace.run(action) }
                .fontWeight(.semibold).foregroundStyle(palette.ink)
                .padding(.trailing, 16).padding(.leading, 8).frame(minHeight: 44)
                .contentShape(.rect)
            }
        }
        .font(font.weight(.medium)).lineLimit(lines)
        .fixedSize(horizontal: false, vertical: lines > 1)
    }
}
#endif
