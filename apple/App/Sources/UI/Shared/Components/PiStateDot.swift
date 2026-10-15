import CueStore
import SwiftUI

extension PiShown {
    /// 状态色，四种各管一件事：等你确认赭黄、出错与没能送达胭脂、在跑（工作中、话在路上）晴蓝、有新回复石绿；
    /// 停着的（该你了、新会话、未知）灰，需要 /reload 次要墨色，已结束更淡的灰。
    func tint(_ palette: Palette) -> Color {
        switch status {
        case .asking: Waiting.tint(dark: palette.dark)
        // 等 Cue 回答：不是要你管的，中性的墨色（赭黄只给等你确认的）
        case .cueAsking: palette.ink
        case .failed, .delivery(.failed): palette.failure
        case .working, .delivery: palette.live
        case .unread: palette.replied
        case .restart: palette.ink2
        case .idle, .resting, .fresh, .interrupted, .unknown: palette.ink3
        case .ended: palette.ink3.opacity(0.6)
        }
    }

    /// 带色的状态（状态词与状态标同色）：要你管的、在跑的、有新回复。
    var isColored: Bool {
        switch status {
        case .asking, .failed, .working, .delivery, .unread: true
        case .cueAsking, .restart, .idle, .resting, .fresh, .ended, .interrupted, .unknown: false
        }
    }

    /// 状态词的颜色：带色的状态与状态标同色，等 Cue 回答是墨色，已结束是灰，其余次要墨色。
    func labelTint(_ palette: Palette) -> Color {
        isColored || status == .cueAsking ? tint(palette) : status == .ended ? palette.ink3 : palette.ink2
    }

    /// Agent 页卡片的底色：要你看的三种（等你确认、出错与没能送达、有新回复）铺一层很淡的状态色，其余是纸。
    /// 在跑的不铺：会动的心电线与蓝字已经够醒目，整屏都上色颜色就不再表示"要你看"。
    func wash(_ palette: Palette) -> Color? { needsYou || isUnread ? tint(palette) : nil }

    /// 状态的静止图形（SF Symbols），与 `tint` 一起是全 App 状态图形的唯一出处：状态标（`PiStateDot`）、跟着字号的
    /// `PiStateGlyph`（问题卡、出错与没能结束的提示、Cue 的等你、前台横幅、通知设置）都从这里取。在跑、话在路上在状态标里是
    /// 自绘的循环动效，这里是减弱动态效果与菜单里的样子。要你看的三种是实心，其余是线条；颜色与里面的字一起分开同为圆的几种。
    var symbol: String {
        switch status {
        case .asking: Waiting.symbol
        // 等 Cue 回答：气泡里的问号，线条墨色（实心赭黄的问号圆只给等你确认的）
        case .cueAsking: "questionmark.bubble"
        // 胭脂圆叹号（`Failure`，与操作出错同一个）：与等你确认的赭黄问号圆靠颜色与里面的字分开
        case .failed: Failure.symbol
        case .delivery(.failed): "arrow.uturn.backward.circle.fill"
        case .restart: "arrow.clockwise.circle"
        case .delivery: "chevron.up.2"
        case .working: "waveform.path.ecg"
        // 铃铛：它回你了，像来了一条通知。不用对勾——对勾只表示完成与记下，任务行旁挨着会话状态时会读成任务做完了
        case .unread: "bell.fill"
        // 输入光标：轮到你打字
        case .idle: "character.cursor.ibeam"
        // 歇着、轮不到你（Cue 值班时）：省略号，等下一句的不是你。不用圈：带圈的已经够多（等你确认、出错、没能送达、要重载、未知、已结束），缩小后分不开
        case .resting: "ellipsis"
        case .fresh: "sparkle"
        // 不用空心圈：待办任务的圆圈就是它
        case .ended: "circle.slash"
        // 断了电：做到一半停下
        case .interrupted: "bolt.slash"
        case .unknown: "questionmark.circle"
        }
    }
}

/// 会话状态标（全 App 只此一份：Agent 页卡片、书架、侧栏、Mac 侧栏与菜单栏、会话页顶栏、任务上的会话状态）：
/// 颜色 + 不带外框的整体图形（符号与颜色只取 `PiShown.symbol`、`tint`）——等你确认赭黄问号圆（外圈一圈波纹慢慢扩开）、出错胭脂圆叹号、没能送达胭脂折回箭头、
/// 在跑晴蓝心电线（一截实色沿波形走）、话在路上晴蓝三层上箭头（从下往上依次亮起）、有新回复石绿铃铛（变成它时摇一下）、
/// 该你了灰色输入光标、新会话灰色星光、已结束更淡的带斜线圈；Cue 值班时，等 Cue 回答是墨色气泡问号、歇着是灰色省略号。`size` 是标的基准直径，外框是它的 1.8 倍，跟着旁边的字随辅助字号放大。
/// 心电线、箭头、波纹是常驻循环动效，交给 Core Animation（`LoopLayer`），不在屏幕上时不画；换状态时旧图形缩小淡出、新图形放大淡入，
/// 两个都是 SF Symbols 时由系统原地替换。减弱动态效果时循环动效换成同一状态的静止符号，没有波纹与摇铃。
/// 旁边有状态文字时读屏跳过它；`announces` 时标自己带读屏标签。
struct PiStateDot: View {
    let shown: PiShown
    var size: CGFloat = 8
    var announces = false
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric private var scale: CGFloat = 1
    /// 每变成一次有新回复加一：铃铛摇一下。
    @State private var rings = 0

    private var box: CGFloat { size * 1.8 * scale }
    /// 字的中线在基线以上多高，按标的外框算（外框约等于旁边的字号）。
    private nonisolated static let midline = 0.36

    /// 画法：自绘的循环动效，或一个静止符号。换画法时整块换（缩放淡入淡出），同为符号时原地替换。
    private enum Look: Hashable { case heartbeat, climb, symbol }

    private var look: Look {
        guard !reduceMotion else { return .symbol }
        switch shown.status {
        case .working: return .heartbeat
        case .delivery(.failed): return .symbol
        case .delivery: return .climb
        default: return .symbol
        }
    }

    var body: some View {
        let tint = shown.tint(palette)
        let mark = ZStack {
            switch look {
            case .heartbeat: LoopLayer(kind: .heartbeat, color: tint).transition(Self.swap)
            case .climb: LoopLayer(kind: .climb, color: tint).transition(Self.swap)
            case .symbol:
                Image(systemName: shown.symbol)
                    .font(.system(size: box * 0.86, weight: .semibold))
                    .foregroundStyle(tint)
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.wiggle, options: .nonRepeating, value: rings)
                    .background {
                        if shown.status == .asking, !reduceMotion { LoopLayer(kind: .ripple, color: tint).frame(width: box * 0.86, height: box * 0.86) }
                    }
                    .transition(Self.swap)
            }
        }
        .frame(width: box, height: box)
        .animation(Motion.quick, value: shown)
        .onChange(of: shown.isUnread) { _, unread in if unread, !reduceMotion { rings += 1 } }
        // 旁边是字时按第一行对齐（`.firstTextBaseline`）：每种标都把自己的中心放在那一行字的中线上。不能用各自的基线——
        // 符号有基线、自绘的动效没有（落到底边），同一列里就高高低低；标的大小跟着旁边的字走，中线离基线约是字高的四成
        .alignmentGuide(.firstTextBaseline) { [box] in $0[VerticalAlignment.center] + box * Self.midline }
        if announces {
            // 只给读屏：每行一个悬停提示会让整页每行都挂一块跟踪区，滚动时跟着重算
            mark.accessibilityLabel(shown.presence)
        } else {
            mark.accessibilityHidden(true)
        }
    }

    private static let swap = AnyTransition.scale(scale: 0.6).combined(with: .opacity)
}

/// 状态的静止图形，大小跟着旁边的字（问题卡、出错与没能结束的提示、Cue 的等你、前台横幅、气泡上的没能送达）：
/// 与状态标同一份符号与颜色（`PiShown.symbol`、`tint`），不带动效。读屏跳过，意思由旁边的字说。
struct PiStateGlyph: View {
    let status: PiShown.Status
    @Environment(\.palette) private var palette

    var body: some View {
        let shown = PiShown(status: status)
        Image(systemName: shown.symbol).foregroundStyle(shown.tint(palette)).accessibilityHidden(true)
    }

    /// 没能送达（会话行的"有话没送到"、气泡上的标记）：样子不随原因变，这里不带原因。
    static let undelivered = PiStateGlyph(status: .delivery(.failed(.timedOut)))
}
