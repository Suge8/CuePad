import SwiftUI

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
