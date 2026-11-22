import SwiftUI

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

/// App 与小组件同一份：等你的与工作中的各几件（`CueNow.counts`），没有就不占地方。头像那一层（`cueDisc`、`cueMarks`，扩展里的头像 `CueNowFace`；App 里会动的头像 `CueAvatar` 套同一层）也在这里。
struct CueLedger: View {
    let now: CueNow
    @Environment(\.palette) private var palette

    var body: some View {
        let counts = now.counts
        if !counts.isEmpty {
            Text(line(counts))
                .monospacedDigit()
                .foregroundStyle(palette.ink2)
                .contentTransition(.numericText())
                .animation(Motion.fade, value: counts)
                .transition(.opacity)
                .accessibilityLabel(Dotted(counts.map(\.words)).spoken)
        }
    }

    private func line(_ counts: [CueNow.Entry]) -> AttributedString {
        counts.enumerated().reduce(into: AttributedString()) { line, next in
            if next.offset > 0 { line += AttributedString(Dotted.separator) }
            line += next.element.line(number: next.element.tone.color(palette))
        }
    }
}

extension CueNow.Entry {
    /// 数接词（"3 等你"）：每种一个整句的键，英文的语序在目录里；数加粗、着 `number` 色，词随外面。
    /// 数以整数进键（"%lld 等你"），不以 `Text` 插进去：后者的键是"%@ 等你"，与别处同字的句子撞成一条、只能有一种英文。
    func line(number: Color) -> AttributedString {
        var line = AttributedString(words)
        if let digits = line.range(of: String(count)) {
            line[digits].foregroundColor = number
            line[digits].inlinePresentationIntent = .stronglyEmphasized
        }
        return line
    }

    var words: String {
        switch kind {
        case .waiting: String(localized: "\(count) 等你")
        case .working: String(localized: "\(count) 工作中")
        }
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

