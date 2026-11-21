import SwiftUI

struct BoardWell: View {
    @Environment(\.palette) private var palette

    var body: some View {
        RoundedRectangle(cornerRadius: TaskMetrics.cardRadius).strokeBorder(palette.hair, style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
    }
}

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
                    .mask {
                        RoundedRectangle(cornerRadius: TaskMetrics.cardRadius)
                            .frame(width: (held.home?.size ?? held.size).width, height: (held.home?.size ?? held.size).height)
                    }
                    .modifier(Floating(moves: moves, settling: held.phase == .settling, landing: held.phase == .landing, fading: held.home != nil || held.phase == .leaving))
            }
        }
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .medium), trigger: moves?.float != nil && moves?.held?.phase == .dragging) { _, lifted in lifted }
        .sensoryFeedback(.selection, trigger: moves?.making)
        .sensoryFeedback(.selection, trigger: moves?.over) { _, over in over != nil }
        .sensoryFeedback(.impact(weight: .light), trigger: moves?.held?.phase) { $0 == .dragging && $1 != .dragging }
        .onChange(of: drags?.current) { if drags?.current == nil { moves?.systemEnded() } }
        .onChange(of: workspace.asksAboutDrop, initial: true) { moves?.asking = workspace.asksAboutDrop }
        .onChange(of: workspace.dropDeclines) { moves?.decline() }
    }

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
                .opacity(fading ? 0 : 1)
                .position(moves.point)
                .animation(Motion.release, value: settling)
                .animation(Motion.travel, value: landing)
                .onAppear { withAnimation(Motion.press) { raised = true } }
        }
    }
}
