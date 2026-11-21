import SwiftUI

enum HandOff {
    static func wording(_ text: String) -> String {
        text.replacingOccurrences(of: "\\p{Nd}+(?:[.,]\\p{Nd}+)*", with: "#", options: .regularExpression)
    }
}

extension AnyTransition {
    static let handOff = AnyTransition.asymmetric(
        insertion: .opacity.animation(Motion.fade.delay(Motion.Fade.yield)), removal: .opacity.animation(Motion.yield))
}

extension View {
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

/// App、小组件、灵动岛与锁屏同一份：数字账（`CueLedger`）与头像的那一层（`cueDisc`、`cueMarks`，扩展里的头像 `CueNowFace`；App 里会动的头像 `CueAvatar` 套同一层）。
/// 排得下哪排画哪排（`CueNow.ledger` 由细到粗），最粗那排还放不下先收紧间距，再不够去掉推进中那组；要你管的那组（拍板、新回复）永远写全、不截。
/// `LedgerFit` 在一次布局里选排并直接画字，首帧不等回填。
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
    /// 数以整数进键（"%lld 新回复"），不以 `Text` 插进去：后者的键是"%@ 新回复"，与"会话名 新回复"撞成一条、只能有一种英文。
    /// 按纯文字取译文再给数上色：`AttributedString(localized:)` 每次要走一遍带格式的拼装与 Markdown 解析，数字账每排都要几个、侧栏名片冷启动就要排。
    func text(number: Color) -> Text { Text(line(number: number)) }

    func line(number: Color) -> AttributedString {
        let words = switch kind {
        case .asks: String(localized: "\(count) 拍板")
        case .reply: String(localized: "\(count) 新回复")
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

struct CueFaceMarks: ViewModifier {
    let size: CGFloat
    let beat: CueBeat
    var badge: Int? = nil
    var rim: Color?
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let awayOpacity = 0.5
    static func dotSide(_ size: CGFloat) -> CGFloat { max(size * 0.26, 6) }

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
                        .transition(Motion.pop(reduceMotion: reduceMotion))
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
                        .transition(Motion.pop(reduceMotion: reduceMotion))
                }
            }
    }
}

extension View {
    func cueDisc(size: CGFloat, filled: Bool = true) -> some View {
        modifier(CueDisc(size: size, filled: filled))
    }

    func cueMarks(size: CGFloat, beat: CueBeat, badge: Int? = nil, rim: Color? = nil) -> some View {
        modifier(CueFaceMarks(size: size, beat: beat, badge: badge, rim: rim))
    }
}

private struct CueDisc: ViewModifier {
    let size: CGFloat
    let filled: Bool
    @Environment(\.palette) private var palette

    func body(content: Content) -> some View {
        content.frame(width: size, height: size).background(filled ? palette.hair : .clear, in: .circle)
    }
}

struct CueNowFace: View {
    let now: CueNow
    let size: CGFloat
    var badge = false
    var rim: Color?
    var disc = true
    @Environment(\.isLuminanceReduced) private var dimmed

    var body: some View {
        Image(decorative: now.beat.still).resizable().scaledToFit().padding(disc ? size * 0.06 : 0)
            .contentTransition(dimmed ? .identity : .opacity)
            .animation(dimmed ? nil : Motion.fade, value: now.beat)
            .cueDisc(size: size, filled: disc)
            .cueMarks(size: size, beat: now.beat, badge: badge ? now.needsYou : nil, rim: rim)
            .readerHidden(true)
    }
}

extension CueNow.Tone {
    func color(_ palette: Palette) -> Color {
        switch self {
        case .moving: palette.signature
        case .asks: palette.waiting
        case .reply: palette.replied
        case .done: palette.replied
        case .quiet: palette.ink3
        }
    }
}

