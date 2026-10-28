import QuartzCore
import SwiftUI

/// 动效 token：App 与扩展、SwiftUI 与渲染端（Core Animation）同一份，按用途分，调用处只说是哪一种，不另写曲线与时长。
/// 动效告诉用户东西去了哪（docs/ui.md）：位置与尺寸用无回弹的弹簧（Apple 自 iOS 17 的默认：按时长与回弹描述，从当前呈现值继续、天然可打断，
/// 回弹 0 是"最通用"的那种，WWDC23 Animate with springs），时长随距离：小位移 `nudge`，远距离 `travel`；
/// 终点时刻有别的事要接着做、或滚动这类收尾不许拖尾巴的，用定长的 `glide`；不挪位置的出现消失、换色、悬停只淡（`fade`）。
/// 回弹只给松手（`release`）：释放本身是手势的收尾，带一点回弹像纸被放开时弹回来；菜单、面板、卡片的出现不弹。
/// 常驻的循环（`LoopLayer`、头像帧序列的 `Motion.Beat`）与 Cue 和会话之间的接力（`CueRelayStage`）是编排，节奏与曲线在它们自己那里，不在这套里。
/// 减弱动态效果的规矩只在 `spatial` 与 `fading`。不隔离：iOS 上转场的效果在渲染线程上求值（`boardFlight`）。
nonisolated enum Motion {
    /// 小位移：列表里让位、面板与浮层开合、展开收起、切换、计数滚动。0.25 秒，一屏里挪几十上百点时跟手。
    /// 手机切 tab（三页那一条整屏平移）与底部那一排换形（Cue 钮长成输入框）也是它：虽横过整屏，是点了就要到的控件，用户定的不比列表里慢。
    static let nudge = Animation.spring(Spring.nudge)
    /// 接着手指速度的 `nudge`（横滑切 tab 松手：初速度按剩下的距离归一，同 Core Animation 那一份 `UIView.animate(springDuration:)`）。
    static func nudge(velocity: Double) -> Animation { .interpolatingSpring(Spring.nudge, initialVelocity: velocity) }
    /// 远距离的空间移动：卡在看板上换列、在墙上换位。0.4 秒：时长随距离长（Material「距离越远时长越长」，大的转场 375～400ms；
    /// Apple 默认的弹簧 0.5 秒），0.25 秒的弹簧前 50ms 就走掉三成多，飞过两三列（上千点）看着是一跳。
    static let travel = Animation.spring(Spring.travel)
    /// 定长的挪动：滚到某处、渲染端的平移与缩放（`ContentLift`、Mac 预览的飞出飞回与缩放）。弹簧最后一两像素的尾巴要再画两百多毫秒，
    /// 正压在接着来的那几次更新上；预览飞完要接着落内容、新说的一句要等对话让开再淡入，都按它的终点排。曲线是标准的缓入缓出（Material 2 standard）：
    /// 起步不急（旧的 (0.2, 0, 0, 1) 前 50ms 走掉一半，远一点就是一跳），收尾柔。
    static let glide = Animation.timingCurve(Glide.curve.0, Glide.curve.1, Glide.curve.2, Glide.curve.3, duration: Glide.duration)
    /// 不挪位置的变化：出现消失、换色、透明度、悬停、换了身份的整块交叉淡（`crossfade` 不另设：两块各自淡入淡出用的就是它）。缓出，一落下就有回应。
    static let fade = Animation.easeOut(duration: Fade.duration)
    /// 让位的淡出：同一处先后换两样东西时旧的先淡完（`HandOff`），离开时不压住正滑向终位的内容。
    static let yield = Animation.easeOut(duration: Fade.yield)
    /// 手机按下：快、不回弹，手指一落就到位。
    static let press = Animation.spring(duration: 0.12)
    /// 手机松开：一点回弹（15% 还不觉得弹，只让尾巴利落些，WWDC23）。
    static let release = Animation.spring(duration: 0.3, bounce: 0.15)

    /// 位置、尺寸、旋转的动画；减弱动态效果时直接到终态——一个动画事务里分不出只淡不挪，换曲线照样插值。
    static func spatial(_ animation: Animation, reduceMotion: Bool) -> Animation? {
        reduceMotion ? nil : animation
    }

    /// 减弱动态效果时视图自己不挪、只按同一个状态淡（出现时不缩放、不位移，只剩透明度）的变化：那时照样淡（`fade`），否则走 `animation`。
    static func fading(_ animation: Animation, reduceMotion: Bool) -> Animation {
        reduceMotion ? fade : animation
    }
}

extension Motion {
    /// 弹簧 token 的参数：渲染端照同一条走（`SidebarSlide` 按它取样）。
    nonisolated enum Spring {
        static let nudge = SwiftUI.Spring(duration: 0.25)
        static let travel = SwiftUI.Spring(duration: 0.4)
    }

    /// `glide` 的时长与曲线，渲染端的同一段（`CABasicAnimation`、`NSAnimationContext`）用 `timing`。
    nonisolated enum Glide {
        static let duration: TimeInterval = 0.28
        fileprivate static let curve: (Double, Double, Double, Double) = (0.4, 0, 0.2, 1)
        static var timing: CAMediaTimingFunction {
            CAMediaTimingFunction(controlPoints: Float(curve.0), Float(curve.1), Float(curve.2), Float(curve.3))
        }
    }

    /// `fade`、`yield` 的时长，渲染端的淡出（Mac 预览落地时飞的那张淡掉）与编排里的等候（等旧的淡完再来新的）用它。
    nonisolated enum Fade {
        static let duration: TimeInterval = 0.16
        static let yield: TimeInterval = 0.08
        static var timing: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    }
}
