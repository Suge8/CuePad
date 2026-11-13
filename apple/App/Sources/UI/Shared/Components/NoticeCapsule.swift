import SwiftUI

/// 提示出现的那一处：摆在哪由 `Workspace.noticeInRail` 定，宿主（会话条 `WideRail`、Mac 页头 `NoticeView`、手机与 iPad 页头 `NoticeBanner`）各放一个，
/// 轮到自己才显示。从贴着的那条边浮出来；换下一条时这一颗留在原地，字与宽跟着变，不整颗换。
struct NoticeSlot: View {
    let place: NoticeCapsule.Place
    @Environment(Workspace.self) private var workspace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let notice = workspace.noticeInRail == (place == .rail) ? workspace.notice : nil
        ZStack {
            if let notice {
                NoticeCapsule(notice: notice, place: place)
                    .transition(Motion.surface(from: place == .rail ? .bottom : .top, reduceMotion: reduceMotion))
            }
        }
        // 走得比来得快：收走的东西不该再占着眼睛
        .animation(notice == nil ? Motion.fade : Motion.fading(Motion.nudge, reduceMotion: reduceMotion), value: notice)
    }
}

/// 页头那一排的（`head`）高同那一排：放不下一行时小一号折两行（"这是灵感，没有状态：要做的事另建任务…"截在一行里正好截掉要你做的那一步）；
/// 两行也放不下（辅助字号）就一行截断——读屏照样读全文，点它照样去那里。字号上限同页顶那一排（`FloatingHeaderLayout.largestType`），再大一行也高过这一排。
/// 会话条里的（`rail`）宽只有会话条那么宽：字照原字号折行，高随字长。
/// 只是报个结果的（没有钮、没有去处、不是出错）不接点按，点穿到下面；其余的点字就收（有去处的是去那里），也能拖一下甩走。
/// 停多久在 `Workspace+Notice`：这里只报指针、键盘焦点在不在它上面、读屏开没开（`holdNotice`）。
struct NoticeCapsule: View {
    enum Place: Equatable {
        case head(fills: Bool)
        case rail
    }

    let notice: Workspace.Notice
    let place: Place
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityVoiceOverEnabled) private var voiceOver
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    @State private var landed = false
    @FocusState private var focus: Part?

    private enum Part { case link, action }

    private var held: Bool { hovering || focus != nil || voiceOver || DebugHooks.preset.readerOn }
    private var acts: Bool { notice.link != nil || notice.action != nil }

    var body: some View {
        let height = ControlSize.regular.height
        Group {
            switch place {
            case .head(let fills):
                ViewThatFits(in: .vertical) {
                    row(font: Typography.secondary, lines: 2, inset: ControlSize.regular.verticalPadding)
                    row(font: Typography.meta, lines: 2, inset: Spacing.tight)
                    row(font: Typography.secondary, lines: 1, inset: ControlSize.regular.verticalPadding)
                }
                #if os(iOS)
                .dynamicTypeSize(...FloatingHeaderLayout.largestType)
                #endif
                .frame(maxWidth: fills ? .infinity : nil)
                .frame(height: height)
            case .rail:
                row(font: Typography.secondary, lines: 4, inset: ControlSize.regular.verticalPadding).frame(minHeight: height)
            }
        }
        // 一行时就是胶囊；折了行的四角还是那个弯
        .glass(in: .rect(cornerRadius: height / 2), interactive: acts)
        .elevation(.panel)
        .onHover { hovering = $0 }
        #if os(macOS)
        .presetHover($hovering)
        #endif
        .gesture(DragGesture(minimumDistance: Self.fling).onEnded { _ in workspace.notice = nil })
        .allowsHitTesting(acts || notice.isError)
        .onChange(of: held, initial: true) { was, now in if was != now || now { workspace.holdNotice(now) } }
        .onChange(of: notice.id, initial: true) {
            AccessibilityNotification.Announcement(notice.text.spoken).post()
            landed = false
            withAnimation(Motion.fading(Motion.nudge, reduceMotion: reduceMotion).delay(Motion.Fade.settle)) { landed = true }
        }
        .accessibilityHint(notice.link == nil ? "" : "去那里看看")
        .accessibilityAddTraits(.updatesFrequently)
        // 读屏开着时不自动收：读屏的"关闭"手势收掉
        .accessibilityAction(.escape) { workspace.notice = nil }
    }

    /// 拖出这么远才算甩走：手抖、点偏的不算。
    private static let fling: CGFloat = 16

    /// 字排出来多高就多高（不截）：`ViewThatFits` 按它判断放不放得进这一排；最后一种只排一行，放不下就截断。`inset` 只用来量放不放得下。
    private func row(font: Font, lines: Int, inset: CGFloat) -> some View {
        HStack(spacing: 0) {
            message(inset: inset)
            if let action = notice.action {
                Button(action.title) { workspace.run(action) }
                    .buttonStyle(ControlButtonStyle(kind: .quiet, size: .compact))
                    .focused($focus, equals: .action)
                    .fixedSize()
                    .padding(.trailing, Spacing.tight)
            }
        }
        .font(font.weight(.medium)).lineLimit(lines)
        .fixedSize(horizontal: false, vertical: lines > 1)
    }

    /// 没有去处时不是按钮：停用的按钮整块压淡，字只剩一半深，键盘也不该停在点了没反应的东西上。
    @ViewBuilder private func message(inset: CGFloat) -> some View {
        let label = HStack(spacing: Spacing.glyph) {
            Label { Text(notice.text).contentTransition(.opacity) } icon: {
                // 胶囊落定后图标才冒出来：这一下是"成了"的那个点
                Group {
                    if let status = notice.status { StateGlyph(status: status) } else { Image(notice.tone.icon) }
                }
                .scaleEffect(landed || reduceMotion ? 1 : 0.6).opacity(landed ? 1 : 0)
            }
            if notice.link != nil { Chevron(.forward).foregroundStyle(palette.ink3) }
        }
        .multilineTextAlignment(.leading)
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
            label.onTapGesture { workspace.notice = nil }
        }
    }
}
