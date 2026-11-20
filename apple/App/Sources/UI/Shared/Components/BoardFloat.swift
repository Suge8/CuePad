import SwiftUI

/// 拖着的卡原处的空位，与空列那一格同一种虚线框。
struct BoardWell: View {
    @Environment(\.palette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: TaskMetrics.cardRadius).strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}

/// 浮在手里的那张卡，画在看板最上面一层（`boardStage`）：原处的那张换小列时会被重建，手势与卡都不能长在它身上。
struct BoardFloat: View {
    @Environment(\.boardMoves) private var moves
    @Environment(\.cardDrags) private var drags

    var body: some View {
        ZStack {
            Color.clear
            if let moves, let float = moves.float, let held = moves.held {
                float.face
                    .environment(\.boardRow, float.row)
                    .frame(width: held.size.width, height: held.size.height)
                    .modifier(Floating(moves: moves, settling: held.phase == .settling))
            }
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .medium), trigger: moves?.float != nil) { _, lifted in lifted }
        .sensoryFeedback(.selection, trigger: moves?.making)
        .sensoryFeedback(.selection, trigger: moves?.over) { _, over in over != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: moves?.held?.phase) { $0 == .dragging && $1 != .dragging }
        .onChange(of: drags?.current) { if drags?.current == nil { moves?.systemEnded() } }
    }

    /// 只这一层读手指的位置：每挪一下重算的是位移，不是卡。
    private struct Floating: ViewModifier {
        let moves: BoardMoves
        let settling: Bool
        @State private var raised = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let scale = 1.04

        func body(content: Content) -> some View {
            let up = raised && !settling
            content
                .elevation(up ? .lifted : nil)
                .scaleEffect(up && !reduceMotion ? Self.scale : 1)
                .position(moves.point)
                .animation(Motion.release, value: settling)
                .onAppear { withAnimation(Motion.press) { raised = true } }
        }
    }
}
