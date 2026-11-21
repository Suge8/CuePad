import SwiftUI

struct CueDot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let color = workspace.cue.unread > 0 ? palette.replied : workspace.cue.now.needsYou > 0 ? palette.waiting : nil
        ZStack {
            if let color { StatusDot(color: color).transition(Motion.pop(reduceMotion: reduceMotion)) }
            CueArrival(color: palette.replied)
        }
        .frame(width: StatusDot.size, height: StatusDot.size)
        .animation(Motion.fade, value: color)
        .readerHidden(true)
    }
}

struct CueArrival: View {
    let color: Color
    var reach: CGFloat = 3.2
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var arrivals = 0

    var body: some View {
        ZStack {
            if arrivals > 0 { Ripple(color: color, reach: reach).id(arrivals) }
        }
        .onChange(of: workspace.cue.unread) { old, new in if new > old, !reduceMotion, !services.viewer.viewing.cue { arrivals += 1 } }
        .allowsHitTesting(false)
        .readerHidden(true)
    }

    private struct Ripple: View {
        let color: Color
        let reach: CGFloat
        @State private var spread = false

        var body: some View {
            Circle().stroke(color, lineWidth: 2)
                .scaleEffect(spread ? reach : 1).opacity(spread ? 0 : 1)
                .onAppear { withAnimation(Motion.nudge) { spread = true } }
        }
    }
}
