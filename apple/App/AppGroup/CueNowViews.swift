import SwiftUI

/// 同一处先后换两样东西（状态的一句、你的话到哪了的记号、横幅让回页头）：旧的 `gap` 内淡完、新的晚 `gap` 再淡入——
/// 长短不同的两句同时交叉淡，中间几帧叠成读不出的一团。App 与扩展同一份。
enum HandOff {
    /// 颜色、透明度、悬停这类不移动位置的反馈，全 App 同一条（也是新的那样淡入的曲线）。
    static let quick = Animation.easeOut(duration: 0.16)
    static let gap: Double = 0.08
}

extension AnyTransition {
    static let handOff = AnyTransition.asymmetric(
        insertion: .opacity.animation(HandOff.quick.delay(HandOff.gap)), removal: .opacity.animation(.easeOut(duration: HandOff.gap)))
}

/// "Cue 此刻"（`CueNow`）的现成样子，App、小组件、灵动岛与锁屏同一份：数字账（`CueLedger`）与头像的那一层（`cueFace`，扩展里的头像 `CueNowFace`；
/// App 里会动的头像 `CueAvatar` 套同一层）。颜色只按意思取：拍板赭黄、待回复墨色、在跑与等子代理靛青、刚做完石绿、歇着灰。
/// 数字账：数字按意思上色、加粗，词是次要墨色；要你管的与推进中的两组之间比组里宽一截。排得下哪排画哪排（`CueNow.ledger` 由细到粗），
/// 最粗那排还放不下先收紧间距，再不够才截断。没有可数的写那一句（`CueNow.quietLine`，起不来是胭脂色，不在是次要灰）。数字变了原地滚过去，换了说法先淡掉再淡入（`handOff`）。
/// 否决过：一件一颗珠子接一句——实心空心要背，一句只挑一种说，几件在推进反而看不出。
struct CueLedger: View {
    let now: CueNow
    /// 组里两项之间；两组之间是它的 `groupGap` 倍。
    var gap: CGFloat = 8
    @Environment(\.palette) private var palette

    private static let groupGap: CGFloat = 1.75

    var body: some View {
        ZStack(alignment: .leading) {
            if now.ledger.isEmpty {
                Text(now.quietLine).foregroundStyle(quietTint).lineLimit(1).id(now.quietLine).transition(.handOff)
            } else {
                ViewThatFits(in: .horizontal) {
                    ForEach(Array(now.ledger.enumerated()), id: \.offset) { _, entries in row(entries, gap: gap) }
                    if let last = now.ledger.last {
                        row(last, gap: gap / 2)
                        truncated(last)
                    }
                }
                .transition(.handOff)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.spoken)
    }

    private func row(_ entries: [CueNow.Entry], gap: CGFloat) -> some View {
        let yours = entries.filter { $0.tone == .asks || $0.tone == .reply }
        let moving = entries.filter { $0.tone == .moving }
        return HStack(spacing: gap * Self.groupGap) {
            if !yours.isEmpty { group(yours, gap: gap) }
            if !moving.isEmpty { group(moving, gap: gap) }
        }
        .fixedSize()
    }

    private func group(_ entries: [CueNow.Entry], gap: CGFloat) -> some View {
        HStack(spacing: gap) {
            ForEach(entries) { entry in
                entry.text(number: entry.tone.color(palette)).monospacedDigit().foregroundStyle(palette.ink2)
                    .contentTransition(.numericText(value: Double(entry.count)))
            }
        }
    }

    /// 最粗那排也放不下（字号很大、地方很窄）：同样的字连成一行，截的是要你管的那组，推进中的总数留全（几件在推进一直看得到）。
    private func truncated(_ entries: [CueNow.Entry]) -> some View {
        let yours = entries.filter { $0.tone != .moving }, moving = entries.filter { $0.tone == .moving }
        return HStack(spacing: gap / 2) {
            if !yours.isEmpty { joined(yours).lineLimit(1).truncationMode(.tail) }
            if !moving.isEmpty { joined(moving).lineLimit(1).fixedSize() }
        }
    }

    private func joined(_ entries: [CueNow.Entry]) -> Text {
        let lines = entries.map { $0.line(number: $0.tone.color(palette)) }
        return Text(lines.dropFirst().reduce(into: lines[0]) { $0 += " " + $1 }).foregroundStyle(palette.ink2)
    }

    private var quietTint: Color {
        if case .away(_, let failed) = now.cue { return failed ? palette.failure : palette.ink3 }
        return palette.ink2
    }
}

extension CueNow.Entry {
    /// 数接词（"3 在跑"）：每种一个整句的键，英文的语序在目录里（"3 running"、"1 for you"）；数加粗、着 `number` 色，词随外面。
    /// 数以整数进键（"%lld 待回复"），不以 `Text` 插进去：后者的键是"%@ 待回复"，与"会话名 待回复"撞成一条、只能有一种英文。
    func text(number: Color) -> Text { Text(line(number: number)) }

    func line(number: Color) -> AttributedString {
        var line = switch kind {
        case .asks: AttributedString(localized: "\(count) 拍板")
        case .reply: AttributedString(localized: "\(count) 待回复")
        case .running: AttributedString(localized: "\(count) 在跑")
        case .delegating: AttributedString(localized: "\(count) 等子代理")
        case .advancing: AttributedString(localized: "\(count) 推进中")
        }
        if let digits = line.range(of: String(count)) {
            line[digits].foregroundColor = number
            line[digits].inlinePresentationIntent = .stronglyEmphasized
        }
        return line
    }
}

/// 头像那一层（App 的 `CueAvatar` 与扩展的 `CueNowFace` 同一个样子）：淡底的圆托着吉祥物，没有环；Cue 在一轮里或话在路上时右下一颗靛青的点
/// （同"在线"点的位置），不在时整个变淡；给了 `badge` 时右上角是要你管的几件（拍板加待回复，赭黄，同 App 图标的角标）。
/// `rim` 是点与角标外那一圈的颜色，与头像后面的底同色，把它们从脸上剪开（灵动岛里是黑）。
/// 否决过：头像外一圈状态环、在想时一颗彗星绕着转——看着就是一条加载进度，平时那圈淡墨也把脸压小了一圈。
struct CueFaceLayer: ViewModifier {
    let size: CGFloat
    var busy = false
    var away = false
    var badge: Int? = nil
    var rim: Color?
    @Environment(\.palette) private var palette

    /// 不在时的不透明度。
    static let awayOpacity = 0.5

    func body(content: Content) -> some View {
        let rim = rim ?? palette.paper
        let line = max(size * 0.05, 1.5)
        content
            .frame(width: size, height: size)
            .background(palette.hair, in: .circle)
            .opacity(away ? Self.awayOpacity : 1)
            .overlay(alignment: .bottomTrailing) {
                if busy {
                    Circle().fill(palette.signature).padding(line).background(rim, in: .circle)
                        .frame(width: max(size * 0.26, 7), height: max(size * 0.26, 7))
                        .offset(x: line, y: line)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay(alignment: .topTrailing) {
                if let badge, badge > 0 {
                    Text(badge, format: .number).font(.system(size: max(size * 0.3, 8), weight: .bold)).monospacedDigit()
                        .foregroundStyle(palette.onFill)
                        .padding(.horizontal, size * 0.08).frame(minWidth: size * 0.42, minHeight: size * 0.42)
                        .background(palette.waitingFill, in: .capsule)
                        .padding(line).background(rim, in: .capsule)
                        .offset(x: size * 0.16, y: -size * 0.12)
                        .transition(.scale.combined(with: .opacity))
                }
            }
    }
}

extension View {
    func cueFace(size: CGFloat, busy: Bool = false, away: Bool = false, badge: Int? = nil, rim: Color? = nil) -> some View {
        modifier(CueFaceLayer(size: size, busy: busy, away: away, badge: badge, rim: rim))
    }
}

/// 扩展里的头像：静止的脸（`CueFaceLayer`）；`badge` 时右上角写要你管的几件（灵动岛最小态）。
struct CueNowFace: View {
    let now: CueNow
    let size: CGFloat
    var badge = false
    var rim: Color?

    var body: some View {
        Image(now.mood.asset).resizable().scaledToFit().padding(size * 0.06)
            .cueFace(size: size, busy: now.isBusy, away: now.isAway, badge: badge ? now.needsYou : nil, rim: rim)
            .accessibilityHidden(true)
    }
}

extension CueNow.Tone {
    func color(_ palette: Palette) -> Color {
        switch self {
        case .moving: palette.signature
        case .asks: palette.waiting
        case .reply: palette.ink
        case .done: palette.replied
        case .quiet: palette.ink3
        }
    }
}

