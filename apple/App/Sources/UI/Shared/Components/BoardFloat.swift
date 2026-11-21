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
    @Environment(Workspace.self) private var workspace

    var body: some View {
        ZStack {
            Color.clear
            if let moves, let float = moves.float, let held = moves.held {
                float.face
                    .environment(\.boardRow, float.row)
                    .frame(width: held.size.width, height: held.size.height)
                    // 落下的一路裁成落点那张的大小。只裁、不按插值的宽高重排：重排的话字逐帧挪（`boardFlight`）
                    .mask {
                        RoundedRectangle(cornerRadius: TaskMetrics.cardRadius)
                            .frame(width: (held.home?.size ?? held.size).width, height: (held.home?.size ?? held.size).height)
                    }
                    .modifier(Floating(moves: moves, settling: held.phase == .settling, landing: held.phase == .landing, fading: held.home != nil || held.phase == .leaving))
            }
        }
        .allowsHitTesting(false)
        // 系统拖放放下后换上的那一张不算拎起来
        .sensoryFeedback(.impact(weight: .medium), trigger: moves?.float != nil && moves?.held?.phase == .dragging) { _, lifted in lifted }
        .sensoryFeedback(.selection, trigger: moves?.making)
        .sensoryFeedback(.selection, trigger: moves?.over) { _, over in over != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: moves?.held?.phase) { $0 == .dragging && $1 != .dragging }
        .onChange(of: drags?.current) { if drags?.current == nil { moves?.systemEnded() } }
        .onChange(of: workspace.asksAboutDrop, initial: true) { moves?.asking = workspace.asksAboutDrop }
        .onChange(of: workspace.dropDeclines) { moves?.decline() }
    }

    /// 只这一层读手指的位置：每挪一下重算的是位移，不是卡。
    private struct Floating: ViewModifier {
        let moves: BoardMoves
        let settling: Bool
        let landing: Bool
        let fading: Bool
        @State private var raised = false
        @Environment(\.accessibilityReduceMotion) private var reduceMotion

        private static let scale = 1.04

        func body(content: Content) -> some View {
            let up = raised && !settling && !landing
            content
                .elevation(up ? .lifted : nil)
                .scaleEffect(up && !reduceMotion ? Self.scale : 1)
                // 与滑过去同一个事务（`BoardMoves.land`）：一路淡掉，露出底下已经排成新样子的那张；离开看板的就地淡掉（`leave`）
                .opacity(fading ? 0 : 1)
                .position(moves.point)
                .animation(Motion.release, value: settling)
                .animation(Motion.travel, value: landing)
                .onAppear { withAnimation(Motion.press) { raised = true } }
        }
    }
}
