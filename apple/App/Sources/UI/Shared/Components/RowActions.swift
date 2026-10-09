import SwiftUI
#if os(iOS)
import UIKit
#endif

/// 一行上的动作按钮按什么语义上色（`Palette.actionFill`）：删除胭脂、主动作靛青、其余墨灰；赭黄只给"等你确认"，不在这里。
enum ActionTone: Sendable {
    case primary, neutral, quiet, destructive
}

/// 一行轻扫露出的一个动作（也画成长按菜单里的同一项）：标题、图标、颜色语义与要做的事。
struct RowAction: Identifiable {
    let title: String
    let symbol: String
    let tone: ActionTone
    let run: () -> Void
    var id: String { title }

    init(_ title: String, symbol: String, tone: ActionTone = .neutral, run: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.tone = tone
        self.run = run
    }
}

/// 一行两边的动作：排在前面的在最外侧，一滑到底执行它。灵感与任务的由 `CardMenu.swipes` 推出（`RowSwipes.card`）。
struct RowSwipes {
    var leading: [RowAction] = []
    var trailing: [RowAction] = []
}

/// 动作画成菜单项或系统轻扫按钮：删除带破坏性角色。
struct RowActionButton: View {
    let action: RowAction

    var body: some View {
        Button(action.title, systemImage: action.symbol, role: action.tone == .destructive ? .destructive : nil, action: action.run)
    }
}

#if os(iOS)
extension View {
    /// 系统列表（`List`）里的行：直接用系统的轻扫，按钮按语义上色。
    func listSwipes(_ swipes: RowSwipes) -> some View {
        modifier(ListSwipes(swipes: swipes))
    }

    /// 不在 `List` 里的行（任务大纲、卡片墙）：自绘出与系统轻扫同样的观感与行为——跟手露出圆角按钮，
    /// 松手过半停开、点按钮执行，一滑到底执行最外侧那个（过线一下触感），同一时刻只开一行；没有动作的一边只给一点阻力。
    /// `clipped`：滑开的内容裁在行内（拼在一张纸里的行）；单独的一张卡整张移开，不裁。
    /// 读屏不从这里取动作：同样的事在长按菜单里，缩进与反缩进在任务行自己的读屏动作里。
    func rowSwipes(_ swipes: RowSwipes, clipped: Bool = true) -> some View {
        modifier(SwipeRow(swipes: swipes, clipped: clipped))
    }
}

private struct ListSwipes: ViewModifier {
    let swipes: RowSwipes
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .leading) { buttons(swipes.leading) }
            .swipeActions(edge: .trailing) { buttons(swipes.trailing) }
    }

    private func buttons(_ actions: [RowAction]) -> some View {
        ForEach(actions) { RowActionButton(action: $0).tint(palette.actionFill($0.tone)) }
    }
}

/// 当前停开的那一行：另一行开始轻扫时它收回。
@MainActor @Observable
private final class OpenSwipe {
    static let shared = OpenSwipe()
    var row: UUID?
}

private struct SwipeRow: ViewModifier {
    let swipes: RowSwipes
    let clipped: Bool
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 正值露出左边（leading），负值露出右边。
    @State private var offset: CGFloat = 0
    /// 这次拖动从哪里开始：0 或停开的位置。
    @State private var rest: CGFloat = 0
    @State private var size = CGSize.zero
    @State private var row = UUID()

    /// 每个按钮占的宽度（与系统轻扫的按钮同宽）。
    private static let slot: CGFloat = 74
    private static let pill = CGSize(width: 56, height: 38)
    /// 没有动作的一边最多挪这么多。
    private static let resistance: CGFloat = 12
    /// 行至少这么高才在按钮下写字（矮的任务行只放图标）。
    private static let labelHeight: CGFloat = 72

    private var side: [RowAction] { offset > 0 ? swipes.leading : offset < 0 ? swipes.trailing : [] }
    private var tray: CGFloat { CGFloat(side.count) * Self.slot }
    /// 过了这条线松手就执行最外侧那个：至少多出一个按钮宽，或行宽的六成。
    private var fullSwipe: CGFloat { max(tray + Self.slot, size.width * 0.6) }
    private var armed: Bool { !side.isEmpty && abs(offset) >= fullSwipe }
    private var animation: Animation { Motion.spatial(Motion.snappy, reduceMotion: reduceMotion) }

    func body(content: Content) -> some View {
        let moved = content
            // 停开时点行本身只是收回，不打开它
            .overlay { if rest != 0 { Color.clear.contentShape(.rect).onTapGesture { settle(0) } } }
            .offset(x: offset)
            .background(alignment: offset > 0 ? .leading : .trailing) { if !side.isEmpty { buttons } }
        return Group { if clipped { moved.clipped() } else { moved } }
            .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
            .gesture(HorizontalPan(changed: drag, ended: end))
            .sensoryFeedback(.impact(weight: .medium), trigger: armed) { !$0 && $1 }
            .onChange(of: OpenSwipe.shared.row) { _, open in if open != row, offset != 0 { settle(0) } }
    }

    /// 露出的按钮：最外侧的是第一个；一滑到底时它占满整段、别的收起。
    private var buttons: some View {
        let shown = abs(offset), ordered = offset > 0 ? side : side.reversed()
        let first = side.first?.id
        return HStack(spacing: 0) {
            ForEach(ordered) { action in
                let width = armed ? (action.id == first ? shown : 0) : shown / CGFloat(side.count)
                button(action, width: width, stretched: armed && action.id == first)
            }
        }
        .frame(width: shown, height: size.height)
        .animation(animation, value: armed)
    }

    private func button(_ action: RowAction, width: CGFloat, stretched: Bool) -> some View {
        let progress = min(width / Self.slot, 1)
        return Button { run(action) } label: {
            VStack(spacing: 5) {
                Image(systemName: action.symbol)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(palette.onSignature)
                    .frame(width: stretched ? max(width - 16, Self.pill.width) : Self.pill.width, height: Self.pill.height)
                    .background(palette.actionFill(action.tone), in: .capsule)
                if size.height >= Self.labelHeight {
                    Text(action.title).font(Typography.caption).foregroundStyle(palette.ink2).lineLimit(1).fixedSize()
                }
            }
            .scaleEffect(0.6 + 0.4 * progress)
            .opacity(progress)
            .frame(width: width, height: size.height)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle(scale: 0.9))
        .clipped()
        .accessibilityHidden(true)
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

/// 只接横向的拖：开始时横向速度明显大于纵向、且不在屏幕左缘（那里是返回手势）才开始，不抢列表滚动。
private struct HorizontalPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat) -> Void
    let ended: (_ commits: Bool, _ velocity: CGFloat) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }

    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.delegate = context.coordinator
        return pan
    }

    func handleUIGestureRecognizerAction(_ pan: UIPanGestureRecognizer, context: Context) {
        switch pan.state {
        case .began, .changed: changed(pan.translation(in: pan.view).x)
        case .ended:
            // 松手那一下也可能带着一段位移（快滑时最后一次移动与松手同一帧）
            changed(pan.translation(in: pan.view).x)
            ended(true, pan.velocity(in: pan.view).x)
        case .cancelled, .failed: ended(false, 0)
        default: break
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        private static let edge: CGFloat = 28

        func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
            guard let pan = recognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            return abs(velocity.x) > abs(velocity.y) * 1.5 && pan.location(in: nil).x > Self.edge
        }
    }
}
#endif
