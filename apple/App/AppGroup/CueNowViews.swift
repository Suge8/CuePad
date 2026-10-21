import SwiftUI

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

/// 一排珠子：前 `limit` 颗，多出的写"+N"（连同 `hidden`）。`bead` 给每颗加东西（App 里挂接力的落点）。
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
            if more > 0 {
                Text("+\(more)").font(.system(size: size * 1.45, weight: .semibold)).monospacedDigit().foregroundStyle(palette.ink2)
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

/// Cue 那一行的第二行：一排珠子接那一句（窄处那一句 `headline`）。不在时只写原因（起不来是胭脂色）。字号随外面。
struct CueNowLine<Decorated: View>: View {
    let now: CueNow
    var limit = 4
    @ViewBuilder var bead: (CueNow.Bead, BeadDot) -> Decorated
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(spacing: 7) {
            if !now.beads.isEmpty {
                CueBeads(beads: now.beads, hidden: now.hidden, limit: limit, bead: bead)
            }
            Text(now.headline).foregroundStyle(tint).lineLimit(1)
                // 换一句是换一个视图：旧的往上推走、新的从下面推上来（扩展里也画得出的转场）
                .id(now.headline)
                .transition(.push(from: .bottom))
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
