import CueStore
import SwiftUI

extension SessionShown {
    func tint(_ palette: Palette) -> Color {
        switch status {
        case .asking: palette.waiting
        case .cueAsking: palette.ink
        case .delivery(.preparing), .delivery(.inTransit(.unconfirmed)): palette.ink3
        case .failed, .delivery(.failed): palette.failure
        case .working, .delivery: palette.signature
        case .unread, .awaitsReply: palette.replied
        case .idle, .resting, .fresh, .interrupted, .unknown, .ended: palette.ink3
        }
    }

    var isColored: Bool {
        switch status {
        case .delivery(.preparing), .delivery(.inTransit(.unconfirmed)): false
        case .asking, .awaitsReply, .failed, .working, .delivery, .unread: true
        case .cueAsking, .idle, .resting, .fresh, .ended, .interrupted, .unknown: false
        }
    }

    func labelTint(_ palette: Palette) -> Color {
        isColored || status == .cueAsking ? tint(palette) : status == .ended ? palette.ink3 : palette.ink2
    }

    /// 等你确认不铺：大块的底色压眼，图标与状态字的赭黄已经够醒目；在跑的也不铺：会动的心电线与靛青字已经够醒目。
    func wash(_ palette: Palette) -> Color? {
        switch status {
        case .failed, .delivery(.failed): palette.failureWash
        case .unread, .awaitsReply: palette.repliedWash
        default: nil
        }
    }

    /// 与 `tint` 一起是全 App 状态图形的唯一出处。是线的几种在状态标里由那根线画（`ink`，与这里同一条中线），话在路上是飞着的纸飞机；这里是菜单里与线收起时的样子。
    /// 按要你做什么分档：在问的是气泡问号，有给你的回复是信封，空闲的不画（这里借在跑的心电线静止形，给菜单与经过用）；全是等宽线，不靠颜色单独区分。
    var icon: Icon {
        switch status {
        // 在问：气泡里一个问号。问你的赭黄，问 Cue 的墨色
        case .asking, .cueAsking: .waiting
        // 圆角三角叹号（`Icon.failure`，与操作出错同一个）
        case .failed: .failure
        case .delivery(.preparing): .more
        // 气泡里一个叉：这句没发出去
        case .delivery(.failed): .undelivered
        case .delivery: .onTheWay
        case .working(.delegating): .relay
        case .working(.tool): .tool
        case .working(.compacting): .compacting
        case .working: .session
        // 信封：有一封给你的回复（你还没看的，或 Cue 留给你回的）。不用对勾——对勾只表示完成与记下，任务行旁挨着会话状态时会读成任务做完了
        case .unread, .awaitsReply: .replied
        case .idle, .resting: .session
        case .fresh: .fresh
        // 收工了：月牙。不用单个空心圈：待办任务的圆圈就是它
        case .ended: .ended
        // 拔掉的插头：做到一半进程没了、说一句就插回去接着做——归停着的灰（多半是你自己停的，标红会稀释出错），不用闪电（与"会话有动静"同轮廓）
        case .interrupted: .interrupted
        // 一圈虚线：说不准
        case .unknown: .unknown
        }
    }
}

/// 会话状态标全 App 只此一份，图标与颜色只取 `SessionShown.icon`、`tint`。是线的几种（`ink`）由同一组线变过去（`StateInk`），
/// 其余（出错、没能送达、纸飞机）叠在线上：线收进中心，标从中心弹出来。空闲的线收进中心、什么都不画。已结束不再另淡：灰已在对比度底线上，靠月牙的形状分。
/// 旁边有状态文字时读屏跳过它；`announces` 时标自己带读屏标签。
struct StateDot: View {
    let shown: SessionShown
    var size: CGFloat = 8
    var announces = false
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LoopsPlay private var loops
    @ScaledMetric private var scale: CGFloat = 1
    @State private var calls = 0
    @State private var rings = 0

    private var box: CGFloat { size * 1.8 * scale }
    private nonisolated static let midline = 0.36

    var body: some View {
        let tint = shown.tint(palette)
        let pose = shown.ink
        let mark = ZStack {
            StateInk(pose: pose ?? .hidden, color: tint, loops: loops, morphs: !reduceMotion)
            if pose == nil {
                Group {
                    if shown.flies { OnTheWay(size: box, color: tint) } else { symbol(tint) }
                }
                .transition(reduceMotion ? .opacity : .scale(scale: 0.3).combined(with: .opacity))
            }
        }
        .frame(width: box, height: box)
        .animation(reduceMotion ? Motion.fade : Motion.Ink.pop, value: pose == nil)
        .animation(Motion.fade, value: shown)
        // 铃铛、徽是刚弹出来的新视图：等它落定再晃，晃的值在它出现之前就变了的话它不晃
        .onChange(of: shown.status) { old, new in if new.callsOut, old != new, !reduceMotion { calls += 1 } }
        .task(id: calls) {
            guard calls > 0, (try? await Task.sleep(for: Self.settle)) != nil else { return }
            rings = calls
        }
        // 旁边是字时按第一行对齐（`.firstTextBaseline`）：每种标都把自己的中心放在那一行字的中线上。不能用各自的基线——
        // 符号有基线、自绘的线没有（落到底边），同一列里就高高低低；标的大小跟着旁边的字走，中线离基线约是字高的四成
        Group {
            // 只给读屏：每行一个悬停提示会让整页每行都挂一块跟踪区，滚动时跟着重算
            if announces { mark.iconLabel(shown.presence) } else { mark.readerHidden(true) }
        }
        .alignmentGuide(.firstTextBaseline) { [box] in $0[VerticalAlignment.center] + box * Self.midline }
    }

    private func symbol(_ tint: Color) -> some View {
        Image(shown.icon)
            .font(.system(size: box * 0.86, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.wiggle, options: .nonRepeating, value: rings)
    }

    private static let settle: Duration = .milliseconds(260)
}

extension SessionShown {
    /// 是线的几种状态此刻那根线的样子与动作；nil 时叠一个标（`icon`，话在路上是纸飞机）。
    var ink: InkPose? {
        switch status {
        case .working(.tool): InkPose(shape: .wrench, life: .twist)
        case .working(.compacting): InkPose(shape: .spring, life: .press)
        case .working(.delegating): InkPose(shape: .bot, life: .bot)
        case .working: InkPose(shape: .heartbeat, life: .pulse)
        case .asking: InkPose(shape: .ask, life: .nod)
        case .cueAsking: InkPose(shape: .ask, life: .still)
        case .awaitsReply, .unread: InkPose(shape: .mail, life: .flap)
        // 空闲：不画。同类做法（T3 Code 等）做完又看过的会话只写多久以前；要你看的、在干活的才有标
        case .idle, .resting: .hidden
        case .interrupted: InkPose(shape: .plug, life: .jitter)
        case .ended: InkPose(shape: .moon, life: .rock)
        case .delivery, .failed, .fresh, .unknown: nil
        }
    }

    var flies: Bool {
        switch status {
        case .delivery(.preparing), .delivery(.failed), .delivery(.inTransit(.unconfirmed)): false
        case .delivery: true
        default: false
        }
    }
}

extension SessionShown.Status {
    /// 换进来时晃一下叫你看：出错、没能送达（新回复的信封换进来时自己掀一下盖）。
    var callsOut: Bool {
        switch self {
        case .failed, .delivery(.failed): true
        default: false
        }
    }
}

struct StateGlyph: View {
    let status: SessionShown.Status
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = SessionShown(status: status)
        Image(shown.icon).foregroundStyle(shown.tint(palette))
    }

    static let undelivered = StateGlyph(status: .delivery(.failed(.reported(DeliveryRequest.unexplainedFailure))))
}
