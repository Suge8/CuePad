import SwiftUI

/// 图标的一次性形变（墨块的"软糖"那一下）：压扁、拉长、落地抖两下，以底边为锚；换表情（或换符号）在压得最扁的那一刻，形变把这一下盖住。
/// 只在事件发生的那一拍放一次（放完就停，不常驻）；减弱动态效果时不形变：样子（`look`）变了的旧的先淡完、新的再淡入（`handOff`，两张不同的脸交叉淡会叠出重影），
/// 样子没变的（只多了一颗点）不换身份，里面变了的自己淡入淡出。
/// 用法：`Jelly(value:look:move:) { shown, phase in … }`，`value` 每变一次按 `move(旧, 新)` 挑动作（nil 是不形变、直接换）；
/// `shown` 是此刻该画的值，`phase` 说此刻在这一下的哪一段：换之前（画旧值，可换成过渡的样子，如做完的勾先是一颗点）、刚换上（直到这一下放完）、平时。
/// 一下只有一个时钟：一个从 0 到 1 的线性进度（一次 `withAnimation`），每帧按它在关键帧时间线上取形变（预建的时间线），
/// 进度过了第一步（压得最扁）那一帧画新值——换与形变同一帧，没有回调、关键姿势之间速度连着、总时长就是各步之和。
/// 否决过：每步一次 `withAnimation` 接完成回调——每个关键姿势处速度归零、回调再晚一截，停 50～90ms、总时长长三四成；
/// 关键帧动画加按秒数睡醒再换的任务——两个时钟，睡醒晚了换就落在压扁之后；关键帧修饰里经环境告诉里面换没换——逐帧只改修饰、不重算里面的视图。
/// 还没放完又来一个新值：从此刻画的那个接着换；此刻的形变（`carry`）在新的一下开头 `JellyPose.recover` 秒内平滑地收掉，不弹回一帧。
struct Jelly<Value: Equatable, Content: View>: View {
    let value: Value
    /// 看得出的样子：减弱动态效果时它变了才整只先淡出再淡入。
    let look: (Value) -> AnyHashable
    let move: (Value, Value) -> JellyMove?
    @ViewBuilder let content: (Value, JellyPhase) -> Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var run: JellyRun<Value>
    @State private var progress = 0.0

    init(
        value: Value, look: @escaping (Value) -> AnyHashable, move: @escaping (Value, Value) -> JellyMove?,
        @ViewBuilder content: @escaping (Value, JellyPhase) -> Content
    ) {
        (self.value, self.look, self.move, self.content) = (value, look, move, content)
        _run = State(initialValue: JellyRun(from: value, to: value))
    }

    var body: some View {
        ZStack {
            if reduceMotion {
                content(run.to, .steady).id(look(run.to)).transition(.handOff)
            } else {
                JellyFrame(progress: progress, run: run, content: content)
            }
        }
        .onChange(of: value) { _, new in start(new) }
    }

    private func start(_ new: Value) {
        if reduceMotion {
            // 样子没变时里面的点、变淡跟着这一下淡入淡出；样子变了的由 `handOff` 自带的节奏淡
            return withAnimation(Motion.fade) { run = JellyRun(from: new, to: new) }
        }
        // 上一下画到了哪：画的值与形变都从最后求值的那一帧接着（按墙钟估会比动画实际走到的早一两帧，接上时跳一下）
        let time = run.drawn.time
        let shown = run.shown(at: time)
        let next = JellyRun(from: shown, to: new, move: move(shown, new), carry: run.pose(at: time), origin: run.drawn.progress)
        run = next
        withAnimation(.linear(duration: next.duration)) { progress = next.origin + 1 }
    }
}

/// 此刻在一下软糖的哪一段：换之前、刚换上（到这一下放完）、平时。刚换上给只在进来时放一次的东西用（做完的欢呼，`CueAvatar`）。
enum JellyPhase { case leaving, entering, steady }

/// 一下软糖：从哪个值换到哪个值、放哪个动作、开头要收掉的形变、第几下，以及最后求值的那一刻（`drawn`）。
/// 不嵌在 `Jelly` 里：嵌着就带上 `Value: Equatable`、`Content: View` 两份协议实现，`@State` 在非隔离处用它们会报可能被隔离。
private struct JellyRun<Value> {
    let from: Value
    let to: Value
    let carry: JellyPose
    let origin: Double
    let duration: Double
    let swapAt: Double
    let motionDuration: Double
    let sample: (Double) -> JellyPose
    let drawn = JellyDrawn()

    init(from: Value, to: Value, move: JellyMove? = nil, carry: JellyPose = JellyPose(), origin: Double = 0) {
        self.from = from
        self.to = to
        self.carry = carry
        self.origin = origin
        let steps = move?.steps ?? []
        motionDuration = steps.reduce(0) { $0 + $1.time }
        duration = max(motionDuration, carry == JellyPose() ? 0 : JellyPose.recover)
        swapAt = steps.first?.time ?? 0
        if let move {
            let timeline = move.timeline
            sample = { timeline.value(time: $0) }
        } else {
            sample = { _ in JellyPose() }
        }
    }

    func shown(at time: Double) -> Value {
        guard time < swapAt else { return to }
        return from
    }

    func phase(at time: Double) -> JellyPhase {
        time < swapAt ? .leaving : time < motionDuration ? .entering : .steady
    }

    /// 动作在这一刻的形变，加上开头那段还没收完的 `carry`。
    func pose(at time: Double) -> JellyPose {
        let base = time < motionDuration ? sample(time) : JellyPose()
        let fade = min(max(time / JellyPose.recover, 0), 1)
        return base.adding(carry, weight: 1 - fade * fade * (3 - 2 * fade))
    }
}

/// 最后求值的那一刻（`JellyFrame` 每帧写，`Jelly.start` 读）。
private final class JellyDrawn {
    var time = Double.infinity
    var progress = 0.0
}

/// 进度插值时每帧重算：这一刻的形变、画旧值还是新值、在哪一段。里面的东西不再随这一下的动画插值（点、变淡与姿势同一帧换）。
private struct JellyFrame<Value: Equatable, Content: View>: View, Animatable {
    var progress: Double
    let run: JellyRun<Value>
    let content: (Value, JellyPhase) -> Content

    var animatableData: Double {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        let time = max(0, progress - run.origin) * run.duration
        run.drawn.time = time
        run.drawn.progress = progress
        return content(run.shown(at: time), run.phase(at: time))
            .transaction { $0.animation = nil }
            .modifier(JellyEffect(pose: run.pose(at: time)))
    }
}

/// 形变画在内容上：以底边中点为锚横竖缩放、转，再按高度的比例上下挪。形变每帧由 `JellyFrame` 给，这里不插值（`animatableData` 留空）。
/// 不随主线程隔离：几何效果的协议不带隔离，SwiftUI 可能在渲染线程上求值。
nonisolated private struct JellyEffect: GeometryEffect {
    var pose: JellyPose

    func effectValue(size: CGSize) -> ProjectionTransform {
        let anchor = CGPoint(x: size.width / 2, y: size.height)
        let transform = CGAffineTransform(translationX: -anchor.x, y: -anchor.y)
            .concatenating(CGAffineTransform(scaleX: pose.sx, y: pose.sy))
            .concatenating(CGAffineTransform(rotationAngle: pose.rot * .pi / 180))
            .concatenating(CGAffineTransform(translationX: anchor.x, y: anchor.y + pose.y * size.height))
        return ProjectionTransform(transform)
    }
}

/// 形变的一帧：横竖缩放、绕底边转（度）、竖直位移（按高度的比例，向上为负）。
nonisolated struct JellyPose: Equatable, Sendable {
    var sx = 1.0, sy = 1.0, rot = 0.0, y = 0.0

    /// 被打断时此刻的形变在新的一下开头多久内收掉。
    static let recover = 0.12

    /// 叠上另一个形变（相对静止的偏移）的 `weight` 倍。
    func adding(_ other: JellyPose, weight: Double) -> JellyPose {
        JellyPose(sx: sx + (other.sx - 1) * weight, sy: sy + (other.sy - 1) * weight, rot: rot + other.rot * weight, y: y + other.y * weight)
    }
}

/// 几种一次性形变（借 lab 的软糖关键帧）。Cue 头像的几种拉长不超过 6%、上跳不超过身高的 5%：再多脑袋就顶出头像那块圆，40pt 的名牌里贴着玻璃上沿。
enum JellyMove {
    /// 被叫醒：缩一下蓄力，弹起拉长，落地压扁，抖一下；眼睛在蓄力压到最扁时睁开。
    case wake
    /// 做完、开心：左右各蹦一下。
    case happy
    /// 做完的勾：按下去，勾顶出来时拉长弹起，落回抖一下（任务圈）。
    case pop
    /// 起不来：左右摇两下头，越摇越轻。
    case shake
    /// 换成等子代理、等你：轻轻一弹。
    case nudge
    /// 从一个姿势退出（其余换了样子的都是它）：轻压一下回弹，0.3s。
    case settle

    var timeline: KeyframeTimeline<JellyPose> {
        let steps = steps
        return KeyframeTimeline(initialValue: JellyPose()) {
            KeyframeTrack(\.sx) { for step in steps { CubicKeyframe(step.pose.sx, duration: step.time) } }
            KeyframeTrack(\.sy) { for step in steps { CubicKeyframe(step.pose.sy, duration: step.time) } }
            KeyframeTrack(\.rot) { for step in steps { CubicKeyframe(step.pose.rot, duration: step.time) } }
            KeyframeTrack(\.y) { for step in steps { CubicKeyframe(step.pose.y, duration: step.time) } }
        }
    }

    /// 每一步用多久走到这个姿势，最后一步回到静止。
    var steps: [(time: Double, pose: JellyPose)] {
        switch self {
        case .wake: [
            (0.10, JellyPose(sx: 1.08, sy: 0.9)), (0.15, JellyPose(sx: 0.95, sy: 1.06, y: -0.05)), (0.13, JellyPose(sx: 1.06, sy: 0.92)),
            (0.11, JellyPose(sx: 0.98, sy: 1.03)), (0.1, JellyPose()),
        ]
        case .happy: [
            (0.08, JellyPose(sx: 1.06, sy: 0.92)), (0.14, JellyPose(sx: 0.95, sy: 1.06, rot: -5, y: -0.05)), (0.12, JellyPose(sx: 1.06, sy: 0.93)),
            (0.12, JellyPose(sx: 0.96, sy: 1.05, rot: 5, y: -0.04)), (0.12, JellyPose(sx: 1.04, sy: 0.96)), (0.1, JellyPose()),
        ]
        case .pop: [
            (0.10, JellyPose(sx: 1.12, sy: 0.84)), (0.16, JellyPose(sx: 0.9, sy: 1.12, y: -0.1)), (0.12, JellyPose(sx: 1.06, sy: 0.94)),
            (0.12, JellyPose(sx: 0.98, sy: 1.02)), (0.1, JellyPose()),
        ]
        case .shake: [
            (0.08, JellyPose(sx: 1.04, sy: 0.96)), (0.1, JellyPose(rot: -7)), (0.12, JellyPose(rot: 6)), (0.12, JellyPose(rot: -3)),
            (0.12, JellyPose(rot: 1.5)), (0.1, JellyPose()),
        ]
        case .nudge: [
            (0.08, JellyPose(sx: 1.06, sy: 0.92)), (0.12, JellyPose(sx: 0.96, sy: 1.05, y: -0.04)), (0.1, JellyPose(sx: 1.02, sy: 0.98)), (0.08, JellyPose()),
        ]
        case .settle: [
            (0.08, JellyPose(sx: 1.05, sy: 0.93)), (0.12, JellyPose(sx: 0.98, sy: 1.03)), (0.1, JellyPose()),
        ]
        }
    }

    /// Cue 换拍子时做哪个动作：醒来（从不在、起不来回来，或变成在想）是叫醒，变成做完是开心，起不来摇头，等子代理、等你轻轻一弹；
    /// 其余只要样子变了（换了静止图，或从在听的倾里出来）就轻压回弹——姿势一变必有一个动作，不硬切。点与变淡跟着同一刻换（都在 `Jelly` 画的那个值里，`CueAvatar`）。
    static func cue(_ old: CueBeat, _ new: CueBeat) -> JellyMove? {
        guard old != new else { return nil }
        let asleep: Set<CueBeat> = [.away, .failed]
        if asleep.contains(old) && !asleep.contains(new) || new == .thinking { return .wake }
        switch new {
        case .done: return .happy
        case .failed: return .shake
        case .delegating, .waiting: return .nudge
        default: return old.still != new.still || old == .hearing ? .settle : nil
        }
    }
}
