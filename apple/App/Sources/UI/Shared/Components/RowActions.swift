import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 赭黄只给"等你确认"，不在这里。
enum ActionTone: Sendable {
    case primary, neutral, quiet, destructive

    func fill(_ palette: Palette) -> Color {
        switch self {
        case .primary: palette.signatureFill
        case .destructive: palette.failureFill
        case .neutral: palette.neutralFill
        case .quiet: palette.quietFill
        }
    }
}

struct RowAction {
    let title: LocalizedStringResource
    let icon: Icon
    let tone: ActionTone
    /// 此刻做不了（如 Mac 够不着时改名）：照样列出，置灰；不直接消失，用户才知道有这件事。
    let enabled: Bool
    let run: () -> Void

    init(_ title: LocalizedStringResource, icon: Icon, tone: ActionTone = .neutral, enabled: Bool = true, run: @escaping () -> Void) {
        self.title = title
        self.icon = icon
        self.tone = tone
        self.enabled = enabled
        self.run = run
    }
}

/// 排在前面的在最外侧，一滑到底执行它。
struct RowSwipes {
    var leading: [RowAction] = []
    var trailing: [RowAction] = []
}

/// 按位置加标题区分，同一边就算有两个同名动作也各是各的。
struct RowActionButtons: View {
    let actions: [RowAction]
    var tinted = false
    @Environment(\.palette) private var palette

    var body: some View {
        ForEach(actions.keyed, id: \.key) { item in
            let action = item.action
            Button(action.title, icon: action.icon, role: action.tone == .destructive ? .destructive : nil, action: action.run)
                .tint(tinted ? action.tone.fill(palette) : nil)
                .disabled(!action.enabled)
        }
    }
}

extension [RowAction] {
    var keyed: [(key: String, action: RowAction)] {
        enumerated().map { ("\($0.offset)·\($0.element.title.key)", $0.element) }
    }
}

#if os(iOS)
extension View {
    func listSwipes(_ swipes: RowSwipes) -> some View {
        modifier(ListSwipes(swipes: swipes))
    }

    /// 只认慢慢拖开：快甩、贴着屏幕两边起手是返回（`HorizontalPan`），在行上也照样返回。
    /// `clipped`：滑开的内容裁在行内（拼在一张纸里的行）；单独的一张卡整张移开，不裁。
    func rowSwipes(_ swipes: RowSwipes, clipped: Bool = true) -> some View {
        modifier(SwipeRow(swipes: swipes, clipped: clipped))
    }
}

private struct ListSwipes: ViewModifier {
    let swipes: RowSwipes

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) { RowActionButtons(actions: swipes.leading, tinted: true) }
            .swipeActions(edge: .trailing) { RowActionButtons(actions: swipes.trailing, tinted: true) }
    }
}

@Observable
private final class OpenSwipe {
    static let shared = OpenSwipe()
    var row: UUID?
}

private struct SwipeRow: ViewModifier {
    let swipes: RowSwipes
    let clipped: Bool
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var offset: CGFloat = 0
    @State private var rest: CGFloat = 0
    @State private var size = CGSize.zero
    @State private var row = UUID()

    private static let slot: CGFloat = 74
    private static let pill = CGSize(width: 56, height: 38)
    private static let resistance: CGFloat = 12
    private static let labelHeight: CGFloat = 72
    /// 开始那一刻横向快过这个（点/秒）算快甩：是要返回，不是要露出行的动作（慢慢拖开、看着按钮出来）。
    private static let flick: CGFloat = 600

    private var side: [RowAction] { offset > 0 ? swipes.leading : offset < 0 ? swipes.trailing : [] }
    private var tray: CGFloat { CGFloat(side.count) * Self.slot }
    private var fullSwipe: CGFloat { max(tray + Self.slot, size.width * 0.6) }
    private var armed: Bool { !side.isEmpty && abs(offset) >= fullSwipe }
    private var animation: Animation? { Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) }

    func body(content: Content) -> some View {
        let moved = content
            // 停开时点行本身只是收回，不打开它
            .overlay { if rest != 0 { Color.clear.contentShape(.rect).onTapGesture { settle(0) }.transition(.identity) } }
            .offset(x: offset)
            .background(alignment: offset > 0 ? .leading : .trailing) { if !side.isEmpty { buttons } }
        return Group { if clipped { moved.clipped() } else { moved } }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(HorizontalPan(allows: claims, changed: drag, ended: end))
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { !$0 && $1 }
            .onChange(of: OpenSwipe.shared.row) { _, open in if open != row, offset != 0 { settle(0) } }
            .accessibilityActions { RowActionButtons(actions: swipes.leading + swipes.trailing) }
    }

    private var buttons: some View {
        let shown = abs(offset), keyed = side.keyed, first = keyed.first?.key
        return HStack(spacing: 0) {
            ForEach(offset > 0 ? keyed : keyed.reversed(), id: \.key) { item in
                let outermost = item.key == first
                let width = armed ? (outermost ? shown : 0) : shown / CGFloat(side.count)
                button(item.action, width: width, stretched: armed && outermost)
            }
        }
        .frame(width: shown, height: size.height)
        .animation(animation, value: armed)
    }

    private func button(_ action: RowAction, width: CGFloat, stretched: Bool) -> some View {
        let progress = min(width / Self.slot, 1)
        return Button { run(action) } label: {
            VStack(spacing: Spacing.glyph) {
                Image(action.icon)
                    .font(Typography.body.weight(.semibold))
                    .foregroundStyle(palette.onFill)
                    .frame(width: stretched ? max(width - 16, Self.pill.width) : Self.pill.width, height: Self.pill.height)
                    .background(action.tone.fill(palette), in: .capsule)
                if size.height >= Self.labelHeight {
                    Text(action.title).font(Typography.caption).foregroundStyle(palette.ink2).lineLimit(1).fixedSize()
                }
            }
            .scaleEffect(0.6 + 0.4 * progress)
            .opacity(progress)
            .frame(width: width, height: size.height)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(.button))
        .disabled(!action.enabled)
        .clipped()
        .readerHidden(true)
    }

    /// 这一拖归不归这一行（`velocity` 是开始那一刻的横向速度）：停开着时都归它（拖回去收起）；否则要慢拖、那个方向有动作，快甩让给页上的横拖。
    private func claims(_ velocity: CGFloat) -> Bool {
        rest != 0 || abs(velocity) < Self.flick && !(velocity > 0 ? swipes.leading : swipes.trailing).isEmpty
    }

    private func drag(_ translation: CGFloat) {
        if OpenSwipe.shared.row != row { OpenSwipe.shared.row = row }
        let raw = rest + translation
        let actions = raw > 0 ? swipes.leading : swipes.trailing
        offset = actions.isEmpty ? min(abs(raw) * 0.15, Self.resistance) * (raw < 0 ? -1 : 1) : max(-size.width, min(raw, size.width))
    }

    /// `commits`：手指正常松开；系统取消手势（来电、被别的手势接走）时回到开始的位置。松手时按甩出的方向估落点：过半停开，否则收回。
    private func end(commits: Bool, velocity: CGFloat) {
        guard commits else { return settle(rest) }
        if armed, let first = side.first { return run(first) }
        let projected = offset + velocity * 0.12
        let opens = !side.isEmpty && abs(projected) > tray / 2 && (projected > 0) == (offset > 0)
        settle(opens ? (offset > 0 ? tray : -tray) : 0)
    }

    private func run(_ action: RowAction) {
        settle(0)
        action.run()
    }

    private func settle(_ target: CGFloat) {
        withAnimation(animation) { offset = target }
        rest = target
        if target == 0, OpenSwipe.shared.row == row { OpenSwipe.shared.row = nil }
    }
}

#endif
