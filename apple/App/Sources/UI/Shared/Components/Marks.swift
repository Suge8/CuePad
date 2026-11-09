import SwiftUI

/// 字号只经 `Glyph.chevron`，随动态字体与旁边的字（`Typography.meta`，胶囊与行尾的值）同比缩放：大字号下固定 11 点的箭头挨着放大了的字就看不见。
struct Chevron: View {
    enum Direction { case forward, expand, back }

    let direction: Direction
    @ScaledMetric(relativeTo: .footnote) private var size = Glyph.chevronSize

    init(_ direction: Direction) { self.direction = direction }

    var body: some View {
        Image(icon).font(Glyph.chevron(size)).readerHidden(true)
    }

    private var icon: Icon {
        switch direction {
        case .forward: .forward
        case .expand: .expand
        case .back: .back
        }
    }
}

/// 压在别的图形上时给 `rim`（底下那层的颜色），描一圈与图形分开。
struct StatusDot: View {
    let color: Color
    var rim: Color?

    static let size: CGFloat = 7
    private static let rimWidth: CGFloat = 2

    var body: some View {
        Circle().fill(color).frame(width: Self.size, height: Self.size)
            .padding(rim == nil ? 0 : Self.rimWidth)
            .background(rim ?? .clear, in: .circle)
    }
}
