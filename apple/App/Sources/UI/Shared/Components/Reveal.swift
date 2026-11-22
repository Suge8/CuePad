import SwiftUI

/// 出字：看着时新来的字按一个时钟一个个落下（`RevealClock`），落下后从一团玫红的网点浮起、聚成实心、冷却成墨（`RevealRenderer`），
/// 末尾跟一根细笔尖：在说就亮着，等下一截时呼吸，说完淡掉。
/// 一句话从 Mac 上正在说、到落进过程或回答，是同一个时钟（`RevealLedger` 按文字认）：交接时不重来，没显完的也不一下冒出来。
/// 打开会话、往上翻、离开期间到的直接显示；减弱动态效果时不出字（`MarkdownText`）。
nonisolated enum RevealRole: Equatable {
    /// 正在说的那句：新来就出字，说着时笔尖呼吸。
    case speaking
    /// 对话里最新的那段：看着时新到的才出字。
    case newest
    /// 别的：只接着已在出的。
    case landed
}

/// 一段一段的匀速：每次来字从此刻显示到的地方接着走，速度取基本速度与"积压在 `catchUp` 秒内追平"中较快的。
/// 每个字落下的时刻由它所在那一段算出，显影只看落下了多久：快慢不同时每个字长出来的样子一样。
/// 位置按 UTF-16 数，与系统给字形的位置同一个数法。
nonisolated struct RevealClock: Equatable {
    private struct Leg: Equatable {
        var at, from, to, rate: Double
        var ends: Double { at + max(0, to - from) / rate }
        var develop: Double { min(Motion.Reveal.develop, Motion.Reveal.front / rate) }
    }

    private var legs: [Leg]
    private(set) var length: Int

    init(shown length: Int, at t: Double) {
        self.length = length
        legs = [Leg(at: t, from: Double(length), to: Double(length), rate: Motion.Reveal.pace)]
    }

    var settles: Double { legs.last?.ends ?? 0 }

    func head(_ t: Double) -> Double {
        guard let leg = legs.last else { return Double(length) }
        return min(leg.to, leg.from + leg.rate * max(0, t - leg.at))
    }

    /// 只留最近几段：更早那段里的字早显完了，查不到段就当显完。
    mutating func receive(_ count: Int, at t: Double) {
        let head = head(t)
        legs = legs.suffix(Self.kept) + [Leg(at: t, from: head, to: Double(count), rate: max(Motion.Reveal.pace, (Double(count) - head) / Motion.Reveal.catchUp))]
        length = count
    }

    /// 0 到 1；还没落下的是 nil。
    func progress(_ index: Int, at t: Double) -> Double? {
        let x = Double(index)
        guard x < head(t) else { return nil }
        guard let leg = legs.last(where: { $0.from <= x }) else { return 1 }
        return min(1, max(0, (t - leg.at - (x - leg.from) / leg.rate) / leg.develop))
    }

    private static let kept = 31
}

/// 一个对话区里出过字的那几段，按文字认（正在说的那句与它落库后的那条文字相同，或是后者的开头）；
/// 打开时就在的最新那段也记一笔（不出字），之后再排一遍不当新来的。别的段不记：往上翻时排出来的一串会把正在出的挤掉。
/// 只记着，不触发界面更新：每段的时钟由读它的 `MarkdownText` 在求值时取，求值几遍取的都是同一个。
@MainActor final class RevealLedger {
    private struct Entry {
        var text: String
        var clock: RevealClock?
    }

    private var entries: [Entry] = []
    private let opened = Date.now.timeIntervalSinceReferenceDate

    func clock(for source: String, length: Int, role: RevealRole, at t: Double) -> RevealClock? {
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        if let index = entries.lastIndex(where: { $0.text == text || $0.clock != nil && text.hasPrefix($0.text) }) {
            guard var clock = entries[index].clock else { return nil }
            if clock.length != length { clock.receive(length, at: t) }
            entries[index] = Entry(text: text, clock: clock)
            return role == .speaking || t < clock.settles + Self.linger ? clock : nil
        }
        guard role != .landed else { return nil }
        let opening = t - opened < Self.opening
        let clock: RevealClock? = switch role {
        case .speaking: Self.start(shown: opening ? length : 0, of: length, at: t)
        case .newest where !opening: Self.start(shown: 0, of: length, at: t)
        case .newest, .landed: nil
        }
        entries = entries.suffix(Self.kept) + [Entry(text: text, clock: clock)]
        return clock
    }

    private static func start(shown: Int, of length: Int, at t: Double) -> RevealClock {
        var clock = RevealClock(shown: shown, at: t)
        if shown < length { clock.receive(length, at: t) }
        return clock
    }

    /// 打开对话的这一会儿里排出来的都是早已在的，不出字。
    private static let opening = 1.0
    private static let linger = max(Motion.Reveal.develop, Motion.Reveal.penFade)
    private static let kept = 15
}

extension EnvironmentValues {
    @Entry var revealLedger: RevealLedger?
}

nonisolated struct RevealFrame {
    let clock: RevealClock
    let t: Double
    let pen: Double

    var head: Double { clock.head(t) }
}

/// 一个 `Text` 的出字：它每一段（`\n` 隔开）在整段话里的起点，与它最后一个字之后的位置。
/// 系统给字形的位置每段从 0 数起（Xcode 27 实测），一行的开头不比上一行的结尾靠后、或上一行是空行，就是新的一段。
nonisolated struct RevealRenderer: TextRenderer {
    let frame: RevealFrame
    let starts: [Int]
    let end: Int
    let cell: CGFloat
    let hot: Color
    let warm: Color

    func draw(layout: Text.Layout, in context: inout GraphicsContext) {
        let t = frame.t, head = frame.head, developed = frame.clock.head(t - Motion.Reveal.develop)
        var paragraph = -1, previous: Int?, tip: CGRect?
        for line in layout {
            guard let first = line.first?.characterIndices.first, let last = line.last?.characterIndices.last else {
                paragraph += 1
                previous = nil
                continue
            }
            let low = Self.offset(first), high = Self.offset(last)
            if previous.map({ low <= $0 }) ?? true { paragraph += 1 }
            previous = high
            let base = starts[min(paragraph, starts.count - 1)]
            if Double(base + low) >= head { continue }
            if Double(base + high) < developed {
                context.draw(line)
                tip = line.last?.last?.typographicBounds.rect ?? tip
                continue
            }
            for run in line {
                for slice in run {
                    guard let index = slice.characterIndices.first.map({ base + Self.offset($0) }), let p = frame.clock.progress(index, at: t) else { continue }
                    tip = slice.typographicBounds.rect
                    if p >= 1 {
                        context.draw(slice)
                    } else {
                        var glyph = context
                        develop(slice, p, in: &glyph)
                    }
                }
            }
        }
        if let tip, frame.pen > 0, Double(starts[0]) < head, head <= Double(end) + 1 { pen(after: tip, in: &context) }
    }

    /// 浮上来、网点聚成实心、从玫红经紫冷却回字自己的颜色，刚落下那一下带一点光。
    private func develop(_ slice: Text.Layout.RunSlice, _ p: Double, in context: inout GraphicsContext) {
        let rise = Self.smooth(p / 0.4), cover = Self.smooth(p / 0.45), heat = 1 - Self.smooth(p / 0.32), glow = 1 - Self.smooth(p / 0.22)
        let rect = slice.typographicBounds.rect.insetBy(dx: -2, dy: -2)
        context.translateBy(x: 0, y: (1 - rise) * 3)
        if glow > 0 {
            var halo = context
            halo.opacity = 0.32 * glow
            halo.addFilter(.blur(radius: 4))
            halo.drawLayer { layer in
                layer.draw(slice)
                layer.blendMode = .sourceAtop
                layer.fill(Path(rect.insetBy(dx: -8, dy: -8)), with: .color(hot))
            }
        }
        if rise < 1 { context.addFilter(.blur(radius: (1 - rise) * 1.5)) }
        context.drawLayer { layer in
            if cover < 1 { layer.clip(to: Self.dots(covering: rect, level: cover, cell: cell)) }
            layer.draw(slice)
            guard heat > 0 else { return }
            layer.blendMode = .sourceAtop
            layer.opacity = min(1, heat * 2)
            layer.fill(Path(rect), with: .color(heat > 0.5 ? warm.mix(with: hot, by: (heat - 0.5) * 2) : warm))
        }
    }

    private func pen(after glyph: CGRect, in context: inout GraphicsContext) {
        let height = glyph.height * 0.78, bar = CGRect(x: glyph.maxX + 1.5, y: glyph.midY - height / 2 + 0.5, width: 1.5, height: height)
        var caret = context
        caret.opacity = 0.55 * frame.pen
        caret.fill(Capsule().path(in: bar), with: .color(warm))
    }

    /// `CharacterIndex` 是包着一个整数的冻结结构，没有公开取值的口子。
    private static func offset(_ index: Text.Layout.CharacterIndex) -> Int { unsafeBitCast(index, to: Int.self) }

    private static func smooth(_ x: Double) -> Double {
        let t = min(max(x, 0), 1)
        return t * t * (3 - 2 * t)
    }

    /// 格子对齐排版的原点，跨字连成一片；与 Cue 页的天、思考档位同一张 8×8 阈值表。
    private static func dots(covering rect: CGRect, level: Double, cell: CGFloat) -> Path {
        var path = Path()
        let x0 = Int((rect.minX / cell).rounded(.down)), x1 = Int((rect.maxX / cell).rounded(.up))
        let y0 = Int((rect.minY / cell).rounded(.down)), y1 = Int((rect.maxY / cell).rounded(.up))
        for y in y0..<y1 {
            for x in x0..<x1 where bayer(x, y) < level {
                path.addRect(CGRect(x: CGFloat(x) * cell, y: CGFloat(y) * cell, width: cell, height: cell))
            }
        }
        return path
    }

    private static func bayer(_ cx: Int, _ cy: Int) -> Double {
        let x = (cx & 7) ^ (cy & 7), y = cy & 7
        var v = 0
        for b in 0..<3 { v |= ((x >> b) & 1) << (5 - 2 * b) | ((y >> b) & 1) << (4 - 2 * b) }
        return (Double(v) + 0.5) / 64
    }
}
