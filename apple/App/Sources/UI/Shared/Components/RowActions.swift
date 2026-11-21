import SwiftUI
#if os(iOS)
import UIKit
#endif

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

extension View {
    /// 挂在菜单的内容上。Mac 的右键菜单默认只画字，图标要点名才画；手机的长按菜单本来就画。
    func menuIcons() -> some View { labelStyle(.titleAndIcon) }
}

struct RowSwipes {
    var leading: [RowAction] = []
    var trailing: [RowAction] = []
}

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
    private static let flick: CGFloat = 600

    private var side: [RowAction] { offset > 0 ? swipes.leading : offset < 0 ? swipes.trailing : [] }
    private var tray: CGFloat { CGFloat(side.count) * Self.slot }
    private var fullSwipe: CGFloat { max(tray + Self.slot, size.width * 0.6) }
    private var armed: Bool { !side.isEmpty && abs(offset) >= fullSwipe }
    private var animation: Animation? { Motion.spatial(Motion.nudge, reduceMotion: reduceMotion) }

    func body(content: Content) -> some View {
        let moved = content
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

    private func claims(_ velocity: CGFloat) -> Bool {
        rest != 0 || abs(velocity) < Self.flick && !(velocity > 0 ? swipes.leading : swipes.trailing).isEmpty
    }

    private func drag(_ translation: CGFloat) {
        if OpenSwipe.shared.row != row { OpenSwipe.shared.row = row }
        let raw = rest + translation
        let actions = raw > 0 ? swipes.leading : swipes.trailing
        offset = actions.isEmpty ? min(abs(raw) * 0.15, Self.resistance) * (raw < 0 ? -1 : 1) : max(-size.width, min(raw, size.width))
    }

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
