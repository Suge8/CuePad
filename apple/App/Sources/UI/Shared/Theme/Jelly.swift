import SwiftUI

/// 图标的一次性形变（墨块的"软糖"那一下）：压扁、拉长、落地抖两下，以底边为锚；换表情（或换符号）在压得最扁的那一刻，形变把这一下盖住。
/// 只在事件发生的那一拍放一次（关键帧，放完就停，不常驻）；减弱动态效果时不形变，换的那一下只淡入淡出。
/// 用法：`Jelly(value:move:) { shown, leaving in … }`，`value` 每变一次按 `move(旧, 新)` 挑动作（nil 是不形变、直接换）；
/// `shown` 是此刻该画的值，`leaving` 是换之前那一小段（画的是旧值，可换成过渡的样子，如做完的勾先是一颗点）。
struct Jelly<Value: Equatable & Sendable, Content: View>: View {
    let value: Value
    let move: (Value, Value) -> JellyMove?
    @ViewBuilder let content: (Value, Bool) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 正在放的这一下。
    @State private var play = Play()

    /// 放的动作、换之前的值、第几下（关键帧的触发）：三样总是一起换。
    private struct Play {
        var move: JellyMove?
        var before: Value?
        var count = 0
    }

    /// 画法交给关键帧的内容闭包：那个闭包的签名是 `@Sendable`，捕获不了本视图的 `content`；SwiftUI 只在主线程排视图时调它，
    /// 画法在那里调用与在 `body` 里调用是同一处境。
    private nonisolated struct Draw: @unchecked Sendable {
        let content: (Value, Bool) -> Content
    }

    var body: some View {
        content(value, false)
            .keyframeAnimator(initialValue: JellyPose(), trigger: play.count) { [draw = Draw(content: content), before = play.before, value] _, pose in
                draw.content(pose.swap < 0.5 ? before ?? value : value, pose.swap < 0.5).modifier(JellyShape(pose: pose))
            } keyframes: { _ in
                let steps = play.move?.steps ?? []
                KeyframeTrack(\.sx) { for step in steps { CubicKeyframe(step.pose.sx, duration: step.time) } }
                KeyframeTrack(\.sy) { for step in steps { CubicKeyframe(step.pose.sy, duration: step.time) } }
                KeyframeTrack(\.rot) { for step in steps { CubicKeyframe(step.pose.rot, duration: step.time) } }
                KeyframeTrack(\.y) { for step in steps { CubicKeyframe(step.pose.y, duration: step.time) } }
                KeyframeTrack(\.swap) {
                    MoveKeyframe(0)
                    LinearKeyframe(0, duration: play.move?.swapAt ?? 0)
                    MoveKeyframe(1)
                }
            }
            // 减弱动态效果：换的那一下淡入淡出
            .transaction(value: value) { if reduceMotion { $0.animation = Motion.crossfade } }
            .onChange(of: value) { old, new in
                guard !reduceMotion, let next = move(old, new) else { return }
                play = Play(move: next, before: old, count: play.count + 1)
            }
    }
}

/// 把一帧的形变加到内容上（不放在泛型的 `Jelly` 里：那里的 `@Sendable` 闭包会捕获内容的类型）。
private struct JellyShape: ViewModifier {
    let pose: JellyPose

    func body(content: Content) -> some View {
        content
            .scaleEffect(x: pose.sx, y: pose.sy, anchor: .bottom)
            .rotationEffect(.degrees(pose.rot), anchor: .bottom)
            .visualEffect { [y = pose.y] content, proxy in content.offset(y: y * proxy.size.height) }
    }
}

/// 形变的一帧：横竖缩放、绕底边转（度）、竖直位移（按高度的比例，向上为负）；`swap` 0 画之前的值、1 画现在的。
struct JellyPose {
    var sx = 1.0, sy = 1.0, rot = 0.0, y = 0.0
    var swap = 1.0
}

/// 几种一次性形变（借 lab 的软糖关键帧）。
enum JellyMove {
    /// 被叫醒：缩一下蓄力，弹起拉长，落地压扁，果冻抖两下；眼睛在蓄力压到最扁时睁开。
    case wake
    /// 做完、开心：左右各蹦一下。
    case happy
    /// 做完的勾：按下去，勾顶出来时拉长弹起，落回抖一下。
    case pop

    /// 第几秒换：压得最扁的那一刻，即第一步走完。
    var swapAt: Double { steps[0].time }

    /// 每一步用多久走到这个姿势，最后一步回到静止。
    var steps: [(time: Double, pose: JellyPose)] {
        switch self {
        case .wake: [
            (0.10, JellyPose(sx: 1.1, sy: 0.86)), (0.16, JellyPose(sx: 0.9, sy: 1.14, y: -0.16)), (0.14, JellyPose(y: -0.22)),
            (0.14, JellyPose(sx: 1.12, sy: 0.86)), (0.12, JellyPose(sx: 0.95, sy: 1.06)), (0.12, JellyPose(sx: 1.02, sy: 0.98)), (0.1, JellyPose()),
        ]
        case .happy: [
            (0.08, JellyPose(sx: 1.08, sy: 0.9)), (0.14, JellyPose(sx: 0.92, sy: 1.1, rot: -6, y: -0.18)), (0.12, JellyPose(sx: 1.1, sy: 0.88)),
            (0.12, JellyPose(sx: 0.94, sy: 1.08, rot: 6, y: -0.12)), (0.12, JellyPose(sx: 1.08, sy: 0.92)), (0.12, JellyPose(sx: 0.98, sy: 1.02)),
            (0.1, JellyPose()),
        ]
        case .pop: [
            (0.10, JellyPose(sx: 1.12, sy: 0.84)), (0.16, JellyPose(sx: 0.9, sy: 1.12, y: -0.1)), (0.12, JellyPose(sx: 1.06, sy: 0.94)),
            (0.12, JellyPose(sx: 0.98, sy: 1.02)), (0.1, JellyPose()),
        ]
        }
    }

    /// Cue 的表情变了做哪个动作：从睡着醒来、被叫起来做事（变成在想）是叫醒，变成做完是开心，其余直接换。
    static func cue(_ old: CueMood, _ new: CueMood) -> JellyMove? {
        if old == .sleeping && new != .sleeping || new == .thinking { return .wake }
        if new == .done { return .happy }
        return nil
    }
}
