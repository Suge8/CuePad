import SwiftUI

/// 同一处先后换两样东西（状态的一句、你的话到哪了的记号、横幅让回页头）：旧的 `gap` 内淡完、新的晚 `gap` 再淡入——
/// 长短不同的两句同时交叉淡，中间几帧叠成读不出的一团。App 与扩展同一份（`Motion.quick`、`Motion.handOff` 取自这里）。
enum HandOff {
    static let quick = Animation.easeOut(duration: 0.16)
    static let gap: Double = 0.08
}

extension AnyTransition {
    static let handOff = AnyTransition.asymmetric(
        insertion: .opacity.animation(HandOff.quick.delay(HandOff.gap)), removal: .opacity.animation(.easeOut(duration: HandOff.gap)))
}

/// "Cue 此刻"（`CueNow`）的现成样子，App、小组件、灵动岛与锁屏同一份：珠子（`BeadDot`、`CueBeads`）、珠子加那一句（`CueNowLine`），
/// 扩展里的头像（`CueNowFace`：静止的脸加一圈状态色的环；App 里的头像是会动的 `CueAvatar`，环的颜色同一套）。
/// 颜色只按意思取：在跑与等子代理靛青（实心是在跑，空心是交出去了、等交回）、等你赭黄、刚做完石绿、歇着灰。
struct BeadDot: View {
    let kind: CueNow.Bead.Kind
    var size: CGFloat = 7
    @Environment(\.palette) private var palette

    var body: some View {
        let tint = kind.tone.color(palette)
        Group {
            if kind == .delegating {
                Circle().strokeBorder(tint, lineWidth: max(size * 0.24, 1.5))
            } else {
                Circle().fill(tint)
            }
        }
        .frame(width: size, height: size)
    }
}

/// 接力落在一颗珠子上时那一圈淡光（`RelayFlight` 画在窗口最上层，盖得住字）：多大、珠子后面的字离珠心至少多远。
enum BeadHalo {
    static let radius: CGFloat = 11
    /// 珠子边到后面第一个字的最小距离：光圈不压到"+N"与那一句的头一个字。
    static func clearance(bead size: CGFloat) -> CGFloat { radius - size / 2 + 0.5 }
}

/// 一排珠子：前 `limit` 颗，多出的写"+N"（连同 `hidden`；排满时它的位置一直留着）。`bead` 给每颗加东西（App 里挂接力的落点）。
/// 珠子之间挨得近，"+N"与最后一颗之间让出接力光圈的半径（`BeadHalo`）。
struct CueBeads<Decorated: View>: View {
    let beads: [CueNow.Bead]
    var hidden = 0
    var size: CGFloat = 7
    var limit = 4
    @ViewBuilder var bead: (CueNow.Bead, BeadDot) -> Decorated
    @Environment(\.palette) private var palette

    var body: some View {
        let more = max(beads.count - limit, 0) + hidden
        HStack(spacing: size * 0.55) {
            ForEach(beads.prefix(limit)) { item in
                bead(item, BeadDot(kind: item.kind, size: size)).transition(.scale.combined(with: .opacity))
            }
            // 排满 `limit` 颗时"+N"的位置一直留着、按两位数的宽：N 变了位数或收没了，前面的珠子与后面那一句都不横移
            if beads.count >= limit || more > 0 {
                Text(verbatim: "+99").hidden().overlay(alignment: .leading) {
                    if more > 0 { Text("+\(more)").contentTransition(.numericText(value: Double(more))).transition(.opacity) }
                }
                .font(.system(size: size * 1.45, weight: .semibold)).monospacedDigit().foregroundStyle(palette.ink2)
                .padding(.leading, max(0, BeadHalo.clearance(bead: size) - size * 0.55))
            }
        }
        .accessibilityHidden(true)
    }
}

extension CueBeads where Decorated == BeadDot {
    init(beads: [CueNow.Bead], hidden: Int = 0, size: CGFloat = 7, limit: Int = 4) {
        self.init(beads: beads, hidden: hidden, size: size, limit: limit) { _, dot in dot }
    }
}

/// Cue 那一行的第二行：一排珠子接那一句（窄处那一句 `headline`；放不下时截那一句，珠子与计数不截）。不在时只写原因（起不来是胭脂色）。字号随外面。
struct CueNowLine<Decorated: View>: View {
    let now: CueNow
    var limit = 4
    @ViewBuilder var bead: (CueNow.Bead, BeadDot) -> Decorated
    @Environment(\.palette) private var palette

    var body: some View {
        // 珠子与那一句之间至少让出接力光圈（`BeadHalo`），光落在最后一颗上时不压到头一个字
        HStack(spacing: max(7, BeadHalo.clearance(bead: 7))) {
            if !now.beads.isEmpty {
                // 珠子与"+N"按自己的宽排、不被挤：窄处让位的是后面那一句（截成省略号），计数截成"+…"就读不出几件了
                CueBeads(beads: now.beads, hidden: now.hidden, limit: limit, bead: bead).fixedSize()
            }
            // 换一句原地换：只变了数时数字滚过去（"2 件"到"1 件"）；换了说法整句先淡掉再淡入（`HandOff`），叠在同一处。
            // 占位的是看不见的新句：换句的那一刻宽度就是新句的，淡出中的旧句不撑着排版——居中排的页头里整组随这一下的动画滑到新位置
            // （`CueHeader`），不在旧句淡完时再跳一下。
            // 否决过：整句上推（新旧两句上下错开叠着、越出页头）；整句按数字滚（不同的字逐字纵滚加模糊，中间帧混成"在 路上"）
            Text(now.headline).lineLimit(1).hidden()
                .overlay(alignment: .leading) {
                    ZStack(alignment: .leading) {
                        Text(now.headline).foregroundStyle(tint).lineLimit(1)
                            .contentTransition(.numericText())
                            .id(now.headline.filter { !$0.isNumber })
                            .transition(.handOff)
                    }
                }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.spoken)
    }

    private var tint: Color {
        if case .away(_, let failed) = now.cue { return failed ? palette.failure : palette.ink3 }
        return palette.ink2
    }
}

extension CueNowLine where Decorated == BeadDot {
    init(now: CueNow, limit: Int = 4) { self.init(now: now, limit: limit) { _, dot in dot } }
}

/// 扩展里的头像：静止的脸加一圈环，环的颜色说 Cue 此刻（`ring`，同 App 里 `CueAvatar` 的环）。
struct CueNowFace: View {
    let now: CueNow
    let size: CGFloat
    @Environment(\.palette) private var palette

    var body: some View {
        let line = max(size * 0.075, 1.5)
        ZStack {
            Circle().stroke(now.ring(palette), lineWidth: line).padding(line / 2)
            Image(now.mood.asset).resizable().scaledToFit().padding(line + size * 0.08)
        }
        .frame(width: size, height: size)
        .opacity(now.isAway ? 0.55 : 1)
        .accessibilityHidden(true)
    }
}

extension CueMood {
    /// 头像那圈环的颜色，App 的头像（`CueAvatar`，在做事时换成彗星）与扩展里的同一条：在想靛青，等你赭黄，刚报了做完石绿，其余淡灰。
    func ring(_ palette: Palette) -> Color {
        switch self {
        case .thinking: palette.signature
        case .waiting: palette.waiting
        case .done: palette.replied
        case .sleeping, .listening: palette.track
        }
    }
}

extension CueNow.Tone {
    func color(_ palette: Palette) -> Color {
        switch self {
        case .moving: palette.signature
        case .asks: palette.waiting
        case .done: palette.replied
        case .quiet: palette.ink3
        }
    }
}

extension CueNow {
    /// 头像那圈环：话在路上靛青，其余跟着表情（`CueMood.ring`，App 里的头像同一条）。
    func ring(_ palette: Palette) -> Color {
        if case .hearing = cue { return palette.signature }
        return mood.ring(palette)
    }

    /// 读屏：那一句，接每种活几件。
    var spoken: String {
        let counts = Bead.Kind.allCases.compactMap { kind -> String? in
            let count = beads.count { $0.kind == kind }
            return count > 0 ? "\(kind.label) \(count)" : nil
        }
        return Dotted([headline] + counts).spoken
    }
}
