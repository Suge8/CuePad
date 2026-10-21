import SwiftUI

/// "回到最新"：回复框右上方一颗圆形玻璃钮，向下的箭头；离开后来过新内容时右上角带一个墨色的点。
struct JumpToNewest: View {
    let unseen: Bool
    let action: () -> Void
    @Environment(\.palette) private var palette

    /// 点按区的边长与离可见区右、下边的距离。
    static let size: CGFloat = 44
    static let inset: CGFloat = 10
    /// 它在可见区底部占的高（含上下留白）：右缘刻度区的下沿让到这之上。
    static var clearance: CGFloat { size + 2 * inset }

    var body: some View {
        Button(action: action) {
            Image(.toLatest).font(.body.weight(.semibold)).foregroundStyle(palette.ink)
                .frame(width: 40, height: 40)
                .glass(in: .circle, interactive: true, ink: .clear)
                .overlay(alignment: .topTrailing) {
                    if unseen {
                        Circle().fill(palette.ink).frame(width: 10, height: 10)
                            .overlay(Circle().strokeBorder(palette.desk, lineWidth: 2))
                            .offset(x: -3, y: 3)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                .frame(width: Self.size, height: Self.size)
                .contentShape(.circle)
        }
        .buttonStyle(PressStyle(.button))
        .accessibilityLabel(unseen ? "回到最新，有新内容" : "回到最新")
    }
}
