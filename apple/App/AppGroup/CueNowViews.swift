import SwiftUI

/// 同一处先后换两样东西（状态的一句、你的话到哪了的记号、横幅让回页头）：旧的先让位淡完（`Motion.yield`）、新的晚这么久再淡入（`Motion.fade`）——
/// 长短不同的两句同时交叉淡，中间几帧叠成读不出的一团。App 与扩展同一份。
enum HandOff {
    /// 现成短句没有数值字段（例如顶栏的 Dotted）：数字只影响滚动，不改变句式身份。
    static func wording(_ text: String) -> String {
        text.replacingOccurrences(of: "\\p{Nd}+(?:[.,]\\p{Nd}+)*", with: "#", options: .regularExpression)
    }
}

extension AnyTransition {
    static let handOff = AnyTransition.asymmetric(
        insertion: .opacity.animation(Motion.fade.delay(Motion.Fade.yield)), removal: .opacity.animation(Motion.yield))
}

extension View {
    /// id 只传数据结构的种类序列；空序列在父布局中不占一项。叶子上的 numericText 动画独立于换项动画。
    @ViewBuilder func handOff<Kind: Hashable>(id: [Kind]) -> some View {
        Group {
            if !id.isEmpty {
                ZStack(alignment: .leading) {
                    self.animation(nil, value: id).id(id).transition(.handOff)
                }
                .transition(.handOff)
            }
        }
        .animation(Motion.fade, value: id)
    }

    func rollingCount<Value: Equatable>(_ value: Value) -> some View {
        contentTransition(.numericText()).animation(Motion.fade, value: value)
    }
}

/// "Cue 此刻"（`CueNow`）的现成样子，App、小组件、灵动岛与锁屏同一份：数字账（`CueLedger`）与头像的那一层（`cueDisc`、`cueMarks`，扩展里的头像 `CueNowFace`；
/// App 里会动的头像 `CueAvatar` 套同一层）。颜色只按意思取：拍板赭黄、待回复墨色、推进中与子代理（每件那一行的在跑、等子代理）靛青、刚做完石绿、歇着灰。
/// 数字账：数字按意思上色、加粗，词是次要墨色；要你管的与推进中的两组之间比组里宽一截。排得下哪排画哪排（`CueNow.ledger` 由细到粗），
/// 最粗那排还放不下先收紧间距，再不够去掉推进中那组；要你管的那组（拍板、待回复）永远写全、不截。没有可数的写那一句（`CueNow.quietLine`，起不来是胭脂色，不在是次要灰）。候选排的种类序列变了才整组交接；数字原地滚，只因宽度换排则直切。
/// LedgerFit 在一次布局里选排并直接画字，首帧不等回填。
/// 否决过：一件一颗珠子接一句——实心空心要背，一句只挑一种说，几件在推进反而看不出；`ViewThatFits` 每排一份候选——挑剩的几排也要建出来，真实库冷启动首屏主线程多约 90M 指令。
struct CueLedger: View {
    let now: CueNow
    var gap: CGFloat = 8
    @Environment(\.palette) private var palette

    var body: some View {
        Group {
            if !now.ledger.isEmpty {
                let fit = LedgerFit(now, gap: gap)
                fit {
                    ForEach(fit.items) { entry in
                        entry.text(number: entry.tone.color(palette)).monospacedDigit().foregroundStyle(palette.ink2)
                            .rollingCount(entry.count)
                    }
                }
                .animation(nil, value: now.ledger)
                .handOff(id: now.ledger.map { $0.map(\.kind) })
            } else {
                Text(now.quietLine).foregroundStyle(quietTint).lineLimit(1)
                    .rollingCount(now.quietLine)
                    .handOff(id: [HandOff.wording(now.quietLine)])
            }
        }
        .transition(.handOff)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(now.spoken)
    }

    private var quietTint: Color {
        if case .away(_, let failed) = now.cue { return failed ? palette.failure : palette.ink3 }
        return palette.ink2
    }
}

extension CueNow.Entry {
    /// 数接词（"4 推进中"）：每种一个整句的键，英文的语序在目录里（"4 active"、"1 for you"）；数加粗、着 `number` 色，词随外面。
    /// 数以整数进键（"%lld 待回复"），不以 `Text` 插进去：后者的键是"%@ 待回复"，与"会话名 待回复"撞成一条、只能有一种英文。
    /// 按纯文字取译文再给数上色：`AttributedString(localized:)` 每次要走一遍带格式的拼装与 Markdown 解析，数字账每排都要几个、侧栏名片冷启动就要排。
    func text(number: Color) -> Text { Text(line(number: number)) }

    func line(number: Color) -> AttributedString {
        let words = switch kind {
        case .asks: String(localized: "\(count) 拍板")
        case .reply: String(localized: "\(count) 待回复")
        case .advancing: String(localized: "\(count) 推进中")
        case .subagents: String(localized: "\(count) 子代理")
        }
        var line = AttributedString(words)
        if let digits = line.range(of: String(count)) {
            line[digits].foregroundColor = number
            line[digits].inlinePresentationIntent = .stronglyEmphasized
        }
        return line
    }
}

/// 头像那一层（App 的 `CueAvatar` 与扩展的 `CueNowFace` 同一个样子），点与变淡只读这一拍（`CueBeat.dot`、`faded`）：
/// 淡底的圆（`cueDisc`）托着吉祥物，没有环；右下一颗点——在动靛青、起不来胭脂——圆心正落在头像那块圆的边上（右下 45° 处），
/// 不越出头像的框：挨着胶囊圆头的 Dock 钮里也不被裁；不在时整只变淡；给了 `badge` 时右上角是要你管的几件（拍板加待回复，赭黄，同 App 图标的角标）。
/// `rim` 是点与角标外那一圈的颜色，与头像后面的底同色，把它们从脸上剪开（灵动岛里是黑）。
/// App 里点与变淡挂在会形变的脸上（`cueMarks`，在软糖压得最扁时与姿势同一刻换），淡底的圆不跟着形变。
/// 否决过：头像外一圈状态环、在想时一颗彗星绕着转——看着就是一条加载进度，平时那圈淡墨也把脸压小了一圈。
struct CueFaceMarks: ViewModifier {
    let size: CGFloat
    let beat: CueBeat
    var badge: Int? = nil
    var rim: Color?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 不在时的不透明度。
    static let awayOpacity = 0.5
    /// 点的直径（含外那一圈 rim）。
    static func dotSide(_ size: CGFloat) -> CGFloat { max(size * 0.26, 6) }

    /// 点的圆心往右、往下各离头像圆心多远：落在圆边的右下 45° 处；小到点会越出头像的框时（16pt，点有 6pt 下限）往里收到贴着框。
    /// 接力的光落在这里、从这里发出（`RelayFlight.Scene.dot`）。
    static func dotReach(_ size: CGFloat) -> CGFloat { min(size * 0.5 / 2.squareRoot(), (size - dotSide(size)) / 2) }

    func body(content: Content) -> some View {
        let rim = rim ?? palette.paper
        let line = max(size * 0.05, 1.2)
        content
            .opacity(beat.faded ? Self.awayOpacity : 1)
            .overlay {
                if let dot = beat.dot {
                    Circle().fill(dot == .failed ? palette.failure : palette.signature).padding(line).background(rim, in: .circle)
                        .frame(width: Self.dotSide(size), height: Self.dotSide(size))
                        .offset(x: Self.dotReach(size), y: Self.dotReach(size))
                        .transition(reduceMotion ? .opacity : .scale.combined(with: .opacity))
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
    /// 头像的框与淡底的圆。
    func cueDisc(size: CGFloat) -> some View {
        modifier(CueDisc(size: size))
    }

    /// 头像上的点、变淡与角标（`CueFaceMarks`），挂在 `size` 见方的头像上。
    func cueMarks(size: CGFloat, beat: CueBeat, badge: Int? = nil, rim: Color? = nil) -> some View {
        modifier(CueFaceMarks(size: size, beat: beat, badge: badge, rim: rim))
    }
}

private struct CueDisc: ViewModifier {
    let size: CGFloat
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.frame(width: size, height: size).background(palette.hair, in: .circle)
    }
}

/// 扩展里的头像：这一拍的静止图（`CueBeat.still`）；`badge` 时右上角写要你管的几件（灵动岛最小态）。
struct CueNowFace: View {
    let now: CueNow
    let size: CGFloat
    var badge = false
    var rim: Color?
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        Image(now.beat.still).resizable().scaledToFit().padding(size * 0.06)
            .contentTransition(dimmed ? .identity : .opacity)
            .animation(dimmed ? nil : Motion.fade, value: now.beat)
            .cueDisc(size: size)
            .cueMarks(size: size, beat: now.beat, badge: badge ? now.needsYou : nil, rim: rim)
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

