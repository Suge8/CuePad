import QuartzCore
import SwiftUI

/// 动效 token：App 与扩展、SwiftUI 与渲染端（Core Animation）同一份，按用途分，调用处只说是哪一种，不另写曲线与时长。
/// 动效告诉用户东西去了哪：位置与尺寸用无回弹的弹簧（Apple 自 iOS 17 的默认：按时长与回弹描述，从当前呈现值继续、天然可打断，
/// 回弹 0 是"最通用"的那种，WWDC23 Animate with springs），时长随距离：小位移 `nudge`，远距离 `travel`；
/// 终点时刻有别的事要接着做、或滚动这类收尾不许拖尾巴的，用定长的 `glide`；不挪位置的出现消失、换色、悬停只淡（`fade`）。
/// 回弹只给松手（`release`）：释放本身是手势的收尾，带一点回弹像纸被放开时弹回来；菜单、面板、卡片的出现不弹。
/// 常驻的循环（`LoopLayer`、头像帧序列的 `Motion.Beat`）与 Cue 和会话之间的接力（`CueRelayStage`）是编排，节奏与曲线在它们自己那里，不在这套里。
/// 减弱动态效果的规矩只在 `spatial` 与 `fading`。不隔离：iOS 上转场的效果在渲染线程上求值（`boardFlight`）。
nonisolated enum Motion {
    static let nudge = Animation.spring(Spring.nudge)
    static func nudge(velocity: Double) -> Animation { .interpolatingSpring(Spring.nudge, initialVelocity: velocity) }
    static let travel = Animation.spring(Spring.travel)
    /// 定长的挪动：滚到某处、渲染端的平移与缩放（`ContentLift`、Mac 预览的飞出飞回与缩放）。弹簧最后一两像素的尾巴要再画两百多毫秒，
    /// 正压在接着来的那几次更新上；预览飞完要接着落内容、新说的一句要等对话让开再淡入，都按它的终点排。曲线是标准的缓入缓出（Material 2 standard）：
    /// 起步不急（旧的 (0.2, 0, 0, 1) 前 50ms 走掉一半，远一点就是一跳），收尾柔。
    static let glide = Animation.timingCurve(Glide.curve.0, Glide.curve.1, Glide.curve.2, Glide.curve.3, duration: Glide.duration)
    static let fade = Animation.easeOut(duration: Fade.duration)
    static let yield = Animation.easeOut(duration: Fade.yield)
    static let press = Animation.spring(duration: 0.12)
    static let release = Animation.spring(duration: 0.3, bounce: 0.15)

    static func pop(reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .scale(scale: 0.9).combined(with: .opacity)
    }

    static func surface(from edge: VerticalEdge, reduceMotion: Bool) -> AnyTransition {
        reduceMotion ? .opacity : .offset(y: edge == .top ? -Surface.shift : Surface.shift).combined(with: .scale(scale: 0.97)).combined(with: .opacity)
    }

    nonisolated enum Surface {
        static let shift: CGFloat = 10
    }

    nonisolated enum Turn {
        static let distance: CGFloat = 28
        static func offset(_ edge: HorizontalEdge) -> CGFloat { edge == .leading ? -distance : distance }
    }

    /// 位置、尺寸、旋转的动画；减弱动态效果时直接到终态——一个动画事务里分不出只淡不挪，换曲线照样插值。
    static func spatial(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    static func fading(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

extension Motion {
    nonisolated enum Spring {
        static let nudge = SwiftUI.Spring(duration: 0.25)
        static let travel = SwiftUI.Spring(duration: 0.4)
    }

    nonisolated enum Glide {
        static let duration: TimeInterval = 0.28
        fileprivate static let curve: (Double, Double, Double, Double) = (0.4, 0, 0.2, 1)
        static var unit: UnitCurve { .bezier(startControlPoint: UnitPoint(x: curve.0, y: curve.1), endControlPoint: UnitPoint(x: curve.2, y: curve.3)) }
        static var timing: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: Float(curve.0), Float(curve.1), Float(curve.2), Float(curve.3))
        }
    }

    nonisolated enum Ink {
        static let morph: CGFloat = 0.5
        static let bounce: CGFloat = 0.22
        static let pop = Animation.spring(duration: 0.42, bounce: 0.3)
    }

    /// 出字（`RevealClock`）：平时一秒 `pace` 个字；积压多了提速，在 `catchUp` 秒内追平。手机上回答整段一次到，追平给得宽些，不一闪而过。
    /// 每个字落下后 `develop` 秒显影完：短于 0.4 秒几乎看不出，长于 0.6 秒带色的尾巴拖得太长。
    /// 追得快时同时在显影的不超过 `front` 个字（每个字显影得更快）：一次几百个字半显半隐是一片发灰的字，笔尖跑在空白里。
    nonisolated enum Reveal {
        static let pace = 45.0
        #if os(macOS)
        static let catchUp = 0.8
        #else
        static let catchUp = 2.5
        #endif
        static let develop = 0.4
        static let front = 40.0
        static let penFade = 0.45
    }

    /// 发出的那句从输入框飞进对话（`SendFlight`）：竖着走得比横着快，走出一道先升后靠右的弧；气泡的底在路上长出来。
    /// 气泡 `wait` 内没排出来（没写进库、不在这一页）就原地淡掉。
    nonisolated enum Send {
        static let lift = Animation.spring(duration: 0.32)
        static let drift = Animation.spring(duration: 0.45)
        static let grow = Animation.easeOut(duration: 0.3)
        static let takeoff: CGFloat = 16
        static let wait: Duration = .seconds(1)
    }

    nonisolated enum Write {
        static let delay: Duration = .milliseconds(300)
        static let stroke = Animation.easeOut(duration: 0.45)
    }

    nonisolated enum Fade {
        static let duration: TimeInterval = 0.16
        static let yield: TimeInterval = 0.08
        static let settle: TimeInterval = 0.12
        static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    }
}

#if os(iOS)
extension Motion.Fade {
    @MainActor static func animate(_ changes: @escaping () -> Void) {
        UIView.animate(withDuration: duration, delay: 0, options: [.curveEaseOut, .beginFromCurrentState, .allowUserInteraction], animations: changes)
    }
}
#endif
