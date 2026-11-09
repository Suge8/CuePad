import SwiftUI

/// 铺色的末端落在缝里、或越过缝却不足两个条宽时收在缝前（圆头）：否则缝的另一边留下一小截两头圆的碎块，读成一个点或渲染毛刺（一个条宽的门槛挡不住 62% 对 59% 那种）。
struct MarkedBar: View, Animatable {
    private var values: AnimatablePair<Double, Double>
    private let level: UsageLevel
    @Environment(\.palette) private var palette

    static let height: CGFloat = 11
    private static let thickness: CGFloat = 5
    private static let gap: CGFloat = 2
    private static let line: CGFloat = 1.5

    init(fill: Double, mark: Double?, level: UsageLevel) {
        values = AnimatablePair(fill, mark ?? -1)
        self.level = level
    }

    var animatableData: AnimatablePair<Double, Double> {
        get { values }
        set { values = newValue }
    }

    var body: some View {
        let (fill, mark) = (values.first, values.second)
        let (track, color, ink) = (palette.track, level.ink(palette), palette.ink)
        Canvas { context, size in
            let (t, gap) = (Self.thickness, Self.gap)
            let y = (size.height - t) / 2
            func capsule(_ x: CGFloat, _ width: CGFloat) -> Path { Path(roundedRect: CGRect(x: x, y: y, width: width, height: t), cornerRadius: t / 2) }
            context.fill(capsule(0, size.width), with: .color(track))
            let x = size.width * min(mark, 1)
            var end = size.width * min(max(fill, 0), 1)
            if mark > 0, end > x - gap, end < x + gap + 2 * t { end = x - gap }
            if end > 0 { context.fill(capsule(0, max(end, t)), with: .color(color)) }
            guard mark > 0 else { return }
            context.blendMode = .destinationOut
            context.fill(Path(roundedRect: CGRect(x: x - gap, y: 0, width: gap * 2, height: size.height), cornerRadius: gap), with: .color(.black))
            context.blendMode = .normal
            context.fill(Path(roundedRect: CGRect(x: x - Self.line / 2, y: 0, width: Self.line, height: size.height), cornerRadius: Self.line / 2), with: .color(ink))
        }
        .frame(height: Self.height)
    }
}
