import SwiftUI

struct CircleGlyph<Content: View>: View {
    let fill: Color
    @ViewBuilder let content: () -> Content
    @Environment(\.palette) private var palette

    var body: some View {
        content()
            .frame(width: ComposerMetrics.glyph, height: ComposerMetrics.glyph)
            .background(fill, in: .circle)
            .overlay { Circle().strokeBorder(fill == palette.fill ? palette.hair : .clear, lineWidth: ControlMetrics.stroke) }
            .frame(width: ComposerMetrics.glyphTarget, height: ComposerMetrics.glyphTarget)
            .contentShape(.circle)
    }
}

struct PlusGlyph: View {
    var icon = Icon.add
    var on = false
    var enabled = true
    @Environment(\.palette) private var palette

    var body: some View {
        CircleGlyph(fill: on ? palette.selection : palette.fill) {
            Image(icon).font(Glyph.controlBold)
                .foregroundStyle(enabled ? palette.ink : palette.ink3)
                .contentTransition(.symbolEffect(.replace))
        }
    }
}

struct FloatingGlyph: View {
    let icon: Icon
    @Environment(\.palette) private var palette

    static let face: CGFloat = 40
    static let size: CGFloat = 44
    static let inset = Spacing.item
    static var clearance: CGFloat { size + 2 * inset }

    var body: some View {
        Image(icon).font(Glyph.controlBold).foregroundStyle(palette.ink)
            .frame(width: Self.face, height: Self.face)
            .glass(in: .circle, interactive: true, ink: .clear)
            .frame(width: Self.size, height: Self.size)
            .contentShape(.circle)
    }
}

struct SendGlyph: View {
    enum Phase: Equatable {
        case idle, ready, sending, stop, stopping
        case save(enabled: Bool)
        case start, retry
        case asleep
        case call(enabled: Bool)
        case hangUp
    }

    let phase: Phase
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hops = 0

    init(_ phase: Phase) { self.phase = phase }

    var body: some View {
        CircleGlyph(fill: disc) {
            ZStack {
                switch phase {
                case .sending: onTheWay.transition(.opacity)
                case .stopping: Spinner(.small).transition(.opacity)
                case .idle, .ready, .call, .hangUp:
                    // 发出：飞机往右上飞走淡出（减弱动态效果时只淡出）；离开时用的是离开前那一刻的这一句，所以只有发送飞走
                    glyph.transition(.asymmetric(insertion: .opacity,
                                                 removal: phase == .ready && !reduceMotion ? .offset(Self.flight).combined(with: .opacity) : .opacity))
                default: glyph.transition(.opacity)
                }
            }
            .animation(Motion.fade, value: phase)
        }
        .animation(phase == .sending ? nil : Motion.fade, value: disc)
        .onChange(of: phase) { _, new in if new == .ready, !reduceMotion { hops += 1 } }
    }

    private var disc: Color {
        switch phase {
        case .idle, .sending, .stopping, .save(enabled: false), .call, .asleep: palette.fill
        case .ready, .save(enabled: true), .start, .retry, .stop, .hangUp: palette.action
        }
    }

    private var glyph: some View {
        let (icon, ink, size): (Icon, Color, CGFloat) = switch phase {
        case .stop: (.stop, palette.onAction, 14)
        case .save(let enabled): (.save, enabled ? palette.onAction : palette.ink3, 17)
        case .start: (.start, palette.onAction, 15)
        case .retry: (.retry, palette.onAction, 17)
        case .call(let enabled): (.call, enabled ? palette.ink : palette.ink3, 18)
        case .hangUp: (.close, palette.onAction, 14)
        case .ready: (.send, palette.onAction, Self.sendSide)
        case .asleep: (.mac, palette.ink3, 17)
        default: (.send, palette.ink3, Self.sendSide)
        }
        return Image(icon)
            .font(Glyph.at(size))
            .foregroundStyle(ink)
            // 减弱动态效果时系统把符号的替换换成淡入淡出
            .contentTransition(.symbolEffect(.replace.offUp))
            .symbolEffect(.bounce.up.byLayer, options: .nonRepeating, value: hops)
    }

    private static let sendSide: CGFloat = 22
    private static let flight = CGSize(width: 14, height: -14)

    private var onTheWay: some View { OnTheWay(size: Self.sendSide, color: palette.signature) }
}
