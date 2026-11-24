import SwiftUI

struct Spinner: View {
    enum Size {
        case mini, small, regular
        var side: CGFloat {
            switch self {
            case .mini: 11
            case .small: 15
            case .regular: 20
            }
        }
    }

    var size = Size.small
    @Environment(\.palette) private var palette
    @LoopsPlay private var spins

    init(_ size: Size = .small) { self.size = size }

    var body: some View {
        Group {
            if spins {
                LoopLayer(kind: .orbit, color: palette.ink2)
            } else {
                let width = size.side * 0.14
                Circle().stroke(palette.track, lineWidth: width)
                    .overlay { Circle().trim(from: 0, to: 0.3).stroke(palette.ink2, style: StrokeStyle(lineWidth: width, lineCap: .round)) }
                    .padding(width / 2)
            }
        }
        .frame(width: size.side, height: size.side)
        .accessibilityElement()
        .accessibilityLabel("请稍候")
    }
}

struct OnTheWay: View {
    let size: CGFloat
    let color: Color
    var landed = false
    @LoopsPlay private var flies

    var body: some View {
        Group {
            if flies && !landed {
                LoopLayer(kind: .flight, color: color)
            } else {
                Image(.onTheWay).font(Glyph.at(size * 0.86)).foregroundStyle(color)
            }
        }
        .frame(width: size, height: size)
    }
}
