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

extension View {
    /// 角上的小点（未读、等你）：挂在右上角、探出一点；圆的往里收一档，落在圆周上。
    func cornerDot(round: Bool = false, @ViewBuilder _ dot: () -> some View) -> some View {
        let shift = round ? -Spacing.tight : Spacing.hair
        return overlay(alignment: .topTrailing) { dot().offset(x: shift, y: -shift) }
    }
}
