import SwiftUI

/// 去 Cue 的入口角上的小点：不在 Cue 页时，Cue 那边有事一眼看得到，不打断。新消息（石绿，有新回复的颜色，`CueWatch.unread`）
/// 先于等你（赭黄，"等你"只有它，见 `WaitingCount`）：刚来的那句是此刻的事，等你一直在、在 Cue 页与会话里各有它的卡；都没有不画。
/// 又来一句时点上漾开一圈（`CueArrival`）。挂在 iPad 右侧 Cue 面板的开关、Mac 侧栏收起时的侧栏钮（侧栏的 Cue 一行看不见了）、
/// iPhone 底部 Dock 的 Cue 圆钮（没有等你时；有等你时那里是等你的数）。
struct CueDot: View {
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    static let size: CGFloat = 7

    var body: some View {
        let color = workspace.cue.unread > 0 ? palette.replied : workspace.cue.waiting > 0 ? palette.waiting : nil
        ZStack {
            if let color { Circle().fill(color).transition(.scale.combined(with: .opacity)) }
            CueArrival(color: palette.replied)
        }
        .frame(width: Self.size, height: Self.size)
        .animation(Motion.quick, value: color)
        .accessibilityHidden(true)
    }
}

/// Cue 又说了一句（新消息变多）时从这里漾开一圈，告诉你"又来了"；读掉、变少不漾，有人在看 Cue 页时（`AppServices.cueViewers`）不漾，
/// 减弱动态效果时没有。挂在一直在的视图上（头像、入口的点）：它自己看新消息的数变多，不另存状态，数只在 `CueWatch.unread`。
/// 一圈与别的尺寸动效同一条弹簧（`Motion.snappy`）：余光里抓得住的是突然动起来的那一下，不是动多久；之后靠加粗、墨色与点留着。
/// `reach`：圈扩到自身的几倍（点小、扩得远；头像大、扩一圈就够）。
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
        .onChange(of: workspace.cue.unread) { old, new in if new > old, !reduceMotion, services.cueViewers == 0 { arrivals += 1 } }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private struct Ripple: View {
        let color: Color
        let reach: CGFloat
        @State private var spread = false

        var body: some View {
            Circle().stroke(color, lineWidth: 2)
                .scaleEffect(spread ? reach : 1).opacity(spread ? 0 : 1)
                .onAppear { withAnimation(Motion.snappy) { spread = true } }
        }
    }
}
