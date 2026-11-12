import CueStore
import SwiftUI

extension SessionShown {
    func tint(_ palette: Palette) -> Color {
        switch status {
        case .asking: palette.waiting
        case .cueAsking, .awaitsReply: palette.ink
        case .delivery(.preparing), .delivery(.inTransit(.unconfirmed)): palette.ink3
        case .failed, .delivery(.failed): palette.failure
        case .working, .delivery: palette.signature
        case .unread: palette.replied
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

    /// 等你确认与待回复不铺：大块的底色压眼，图标与状态字的赭黄已经够醒目；在跑的也不铺：会动的心电线与靛青字已经够醒目。
    func wash(_ palette: Palette) -> Color? {
        switch status {
        case .failed, .delivery(.failed): palette.failureWash
        case .unread: palette.repliedWash
        default: nil
        }
    }

    /// 与 `tint` 一起是全 App 状态图形的唯一出处。在跑、话在路上在状态标里是自绘的循环动效，这里是不放循环动效时与菜单里的样子。等你是裸问号，出错与没能送达保留实心圆徽；不靠颜色单独区分。
    var icon: Icon {
        switch status {
        case .asking: .waiting
        case .awaitsReply: .awaitsReply
        case .cueAsking: .cueAsking
        // 胭脂圆叹号（`Icon.failure`，与操作出错同一个）：与等你确认的裸问号靠轮廓与颜色分开
        case .failed: .failure
        case .delivery(.preparing): .more
        case .delivery(.failed): .undelivered
        case .delivery: .onTheWay
        case .working(.delegating): .relay
        case .working: .session
        // 铃铛：它回你了，像来了一条通知。不用对勾——对勾只表示完成与记下，任务行旁挨着会话状态时会读成任务做完了
        case .unread: .replied
        case .idle: .yourTurn
        // 歇着、轮不到你（Cue 值班时）：省略号，等下一句的不是你。不用圈：带圈的已经够多（出错、没能送达、未知、已结束），缩小后分不开
        case .resting: .more
        case .fresh: .fresh
        // 不用空心圈：待办任务的圆圈就是它
        case .ended: .ended
        // 断开的线：做到一半停下、说一句就接着做——归停着的灰（多半是你自己停的，标红会稀释出错），不用闪电（与"会话有动静"同轮廓）
        case .interrupted: .interrupted
        case .unknown: .unknown
        }
    }
}

/// 会话状态标全 App 只此一份，图标与颜色只取 `SessionShown.icon`、`tint`。已结束不再另淡：灰已在对比度底线上，靠斜线圈的形状分。旁边有状态文字时读屏跳过它；`announces` 时标自己带读屏标签。
struct StateDot: View {
    let shown: SessionShown
    var size: CGFloat = 8
    var announces = false
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @LoopsPlay private var loops
    @ScaledMetric private var scale: CGFloat = 1
    @State private var rings = 0

    private var box: CGFloat { size * 1.8 * scale }
    private nonisolated static let midline = 0.36

    var body: some View {
        let tint = shown.tint(palette)
        let mark = ZStack {
            switch shown.mark {
            case .flight: OnTheWay(size: box, color: tint).transition(Motion.pop(reduceMotion: reduceMotion))
            case .loop(let kind) where loops: LoopLayer(kind: kind, color: tint).transition(Motion.pop(reduceMotion: reduceMotion))
            case .loop, .icon: icon(tint)
            }
        }
        .frame(width: box, height: box)
        .animation(Motion.fade, value: shown)
        .onChange(of: shown.isUnread) { _, unread in if unread, !reduceMotion { rings += 1 } }
        // 旁边是字时按第一行对齐（`.firstTextBaseline`）：每种标都把自己的中心放在那一行字的中线上。不能用各自的基线——
        // 符号有基线、自绘的动效没有（落到底边），同一列里就高高低低；标的大小跟着旁边的字走，中线离基线约是字高的四成
        Group {
            // 只给读屏：每行一个悬停提示会让整页每行都挂一块跟踪区，滚动时跟着重算
            if announces { mark.iconLabel(shown.presence) } else { mark.readerHidden(true) }
        }
        .alignmentGuide(.firstTextBaseline) { [box] in $0[VerticalAlignment.center] + box * Self.midline }
    }

    private func icon(_ tint: Color) -> some View {
        Image(shown.icon)
            .font(.system(size: box * 0.86, weight: .semibold))
            .foregroundStyle(tint)
            .contentTransition(.symbolEffect(.replace))
            .symbolEffect(.wiggle, options: .nonRepeating, value: rings)
            .transition(Motion.pop(reduceMotion: reduceMotion))
    }

}

enum StateMark: Equatable {
    case loop(LoopLayer.Kind)
    case flight
    case icon
}

extension SessionShown {
    var mark: StateMark {
        switch status {
        case .working(.delegating): .loop(.relay)
        case .working(.tool): .loop(.orbit)
        case .working: .loop(.heartbeat)
        case .delivery(.preparing), .delivery(.failed), .delivery(.inTransit(.unconfirmed)): .icon
        case .delivery: .flight
        case .asking: .icon
        case .idle, .resting, .fresh, .ended, .interrupted, .unknown, .cueAsking, .awaitsReply, .failed, .unread: .icon
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
