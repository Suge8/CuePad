import SwiftUI

/// 一条提示（`Workspace.notice`）本身，两端同一个：一块实底玻璃胶囊（盖住的名牌、搜索框与正文不能透出来叠字），带去处的点它过去，
/// 右边可有一个动作（撤销、归档；Mac 上撤销另有 ⌘Z）。高是一排控件那一档（`ControlSize.regular`）：一行放得下就一行；放不下时小一号折两行
/// （"这是灵感，没有状态：要做的事另建任务…"截在一行里正好截掉要你做的那一步）；两行也放不下（辅助字号）就一行截断——读屏照样读全文，点它照样去那里。
/// 字号上限同页顶那一排（`FloatingHeaderLayout.largestType`），再大一行也高过这一排。
/// 摆在哪、多宽、怎么进出场由宿主给（Mac `NoticeView`、手机 `NoticeBanner`）。停多久在 `Workspace+Notice`：这里只报指针、键盘焦点在不在它上面、读屏开没开（`holdNotice`）。
struct NoticeCapsule: View {
    let notice: Workspace.Notice
    /// 铺满宿主给的宽（手机盖在页顶那一排中间那块的位置）；否则随字长。
    var fills = false
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @State private var hovering = false
    @FocusState private var focus: Part?

    private enum Part { case link, action }

    private var held: Bool { hovering || focus != nil || voiceOver || DebugHooks.preset.readerOn }

    var body: some View {
        ViewThatFits(in: .vertical) {
            row(font: Typography.secondary, lines: 2, inset: ControlSize.regular.verticalPadding)
            row(font: Typography.meta, lines: 2, inset: Spacing.tight)
            row(font: Typography.secondary, lines: 1, inset: ControlSize.regular.verticalPadding)
        }
        #if os(iOS)
        .dynamicTypeSize(...FloatingHeaderLayout.largestType)
        #endif
        .frame(maxWidth: fills ? .infinity : nil)
        .frame(height: ControlSize.regular.height)
        .glass(in: .capsule, interactive: notice.link != nil || notice.action != nil)
        .elevation(.panel)
        .onHover { hovering = $0 }
        #if os(macOS)
        .presetHover($hovering)
        #endif
        .onChange(of: held, initial: true) { was, now in if was != now || now { workspace.holdNotice(now) } }
        .onAppear { AccessibilityNotification.Announcement(notice.text.spoken).post() }
        .accessibilityHint(notice.link == nil ? "" : "去那里看看")
        .accessibilityAddTraits(.updatesFrequently)
        // 读屏开着时不自动收：读屏的"关闭"手势收掉
        .accessibilityAction(.escape) { workspace.notice = nil }
    }

    /// 字排出来多高就多高（不截）：`ViewThatFits` 按它判断放不放得进这一排；最后一种只排一行，放不下就截断。`inset` 只用来量放不放得下。
    private func row(font: Font, lines: Int, inset: CGFloat) -> some View {
        HStack(spacing: 0) {
            message(inset: inset)
            if let action = notice.action {
                Button(action.title) { workspace.run(action) }
                    .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
                    .focused($focus, equals: .action)
                    #if os(macOS)
                    .keyboardShortcut(action.isUndo ? KeyboardShortcut("z", modifiers: .command) : nil)
                    #endif
                    .padding(.trailing, Spacing.tight)
            }
        }
        .font(font.weight(.medium)).lineLimit(lines)
        .fixedSize(horizontal: false, vertical: lines > 1)
    }

    /// 没有去处时不是按钮：停用的按钮整块压淡，字只剩一半深，键盘也不该停在点了没反应的东西上。
    @ViewBuilder private func message(inset: CGFloat) -> some View {
        let label = HStack(spacing: Spacing.glyph) {
            Label { Text(notice.text) } icon: {
                if let status = notice.status { PiStateGlyph(status: status) } else { Image(notice.tone.icon) }
            }
            if notice.link != nil { Chevron(.forward).foregroundStyle(palette.ink3) }
        }
        .foregroundStyle(notice.isError ? palette.failure : palette.ink)
        .padding(.leading, ControlSize.regular.padding)
        .padding(.trailing, notice.action == nil ? ControlSize.regular.padding : Spacing.tight)
        .padding(.vertical, inset)
        .contentShape(.rect)
        if let link = notice.link {
            Button { workspace.go(to: link) } label: { label }
                .buttonStyle(PressStyle())
                .focused($focus, equals: .link)
        } else {
            label
        }
    }
}
