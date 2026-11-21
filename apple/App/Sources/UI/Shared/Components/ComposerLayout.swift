import SwiftUI

enum ComposerMetrics {
    static let inset = Spacing.item
    static let slot: CGFloat = 56
    static let textTop: CGFloat = 17
    static let textBottomOpen: CGFloat = 4
    #if os(iOS)
    static let glyph = ControlSize.compact.height
    #else
    static let glyph: CGFloat = 32
    #endif
    #if os(iOS)
    static let glyphTarget: CGFloat = 44
    #else
    static let glyphTarget = glyph
    #endif
    static let glyphEdge = (slot - glyph) / 2
    static let glyphInset = (slot - glyphTarget) / 2
    static let noticeSpacing = Spacing.tight
    static let noticePadding = Spacing.item
    static let noticeTextHeight: CGFloat = 2 * 16 + noticeSpacing

    static func noticeClearance(textHeight: CGFloat) -> CGFloat {
        textHeight + 2 * noticePadding + Spacing.item
    }

    static func lineSlot(line: CGFloat) -> CGFloat { max(slot, ceil(line + 2 * textTop)) }
}

/// 文字区要多高（两端的 `ComposerField` 各持一份）：最高只露出 `limit`，所以只排开头够撑满上限的那一段，不排整篇——
/// 粘贴几百行进来后每敲一个字都整篇重排，一个字要两三百毫秒。开头一段排出的高度不会超过整篇的（后面的字只会多出行），
/// 够上限就是上限；不够再排长一倍，排到整篇为止。先排的字数按全角字估（全角字最宽，撑满同样的行数要的字最少）：
/// SwiftUI 每次排版还会拿宽度 0 来探，那时几个字就竖着撑满了，不能一上来就排上千个字；横排里有别的圆钮（Agent 跑一轮时的停止钮）时
/// 还会拿无穷宽来量它最宽能多宽，那时估不出字数，从最短的一段排起（无穷宽、极宽转整数会让 App 崩溃）。
/// 量过的按宽度各记一份（一次排版里会按几种宽度轮流问）；文字变了时，撑满过上限的那段开头没动（接着往后写）就还是上限，不再排。
/// 空着时按一行中文量：空串排出来的行高取决于排版器残留的打字样式（全 App 共用一个量尺，App 开着时改了字号，量出来还是旧字号的一行，
/// 输入框被切掉下半截），也比打下第一个字后矮。
struct ComposerHeight {
    private var fits: [Key: Fit] = [:]
    private var version = 0

    private struct Key: Hashable { var width, em, limit: CGFloat }
    private struct Fit {
        var height: CGFloat
        var filled: NSString?
        var version: Int
    }

    mutating func textChanged() {
        fits = fits.filter { $0.value.version == version && $0.value.filled != nil }
        version += 1
    }

    mutating func height(of text: NSString, width: CGFloat, em: CGFloat, limit: CGFloat, measure: (String) -> CGFloat) -> CGFloat {
        let text = text.length == 0 ? "国" : text
        let key = Key(width: width, em: em, limit: limit)
        if let fit = fits[key] {
            if fit.version == version { return fit.height }
            if let filled = fit.filled, text.hasPrefix(filled as String) {
                fits[key]?.version = version
                return limit
            }
        }
        let fit = Self.fit(text, width: width, em: em, limit: limit, measure: measure)
        fits[key] = Fit(height: fit.height, filled: fit.filled, version: version)
        return fit.height
    }

    private static func fit(
        _ text: NSString, width: CGFloat, em: CGFloat, limit: CGFloat, measure: (String) -> CGFloat
    ) -> (height: CGFloat, filled: NSString?) {
        let estimate = limit / em * width / em
        var length = estimate.isFinite ? max(minSpan, Int(min(estimate, CGFloat(text.length)))) : minSpan
        while length < text.length {
            let prefix = text.substring(to: text.rangeOfComposedCharacterSequence(at: length).location)
            if measure(prefix) >= limit { return (limit, prefix as NSString) }
            length *= 2
        }
        let height = measure(text as String)
        return height >= limit ? (limit, text.copy() as? NSString) : (height, nil)
    }

    private static let minSpan = 16
}

extension String {
    /// 文字区里的字整块拷成原生字符串。文字区的 `text`、`string` 桥接过来是包着可变 NSString 的外来字符串，
    /// 草稿的每个读者（预览、空不空、比较、存偏好）在它上面都逐字走慢路，几百行时每个字要多花几毫秒。
    init(native text: NSString) {
        var units = [unichar](repeating: 0, count: text.length)
        text.getCharacters(&units, range: NSRange(location: 0, length: text.length))
        self.init(decoding: units, as: UTF16.self)
    }
}

enum ComposerForm: Equatable {
    case open
    case line(opensOnFocus: Bool)
    case capsule(opensOnFocus: Bool)

    var opensOnFocus: Bool {
        switch self {
        case .open: true
        case .line(let opens), .capsule(let opens): opens
        }
    }

    var isCapsule: Bool { if case .capsule = self { true } else { false } }

    func expanded(focused: Bool, draft: ComposerDraft, accepts: ComposerKinds) -> Bool {
        if isCapsule && !focused { return false }
        return self == .open || focused && opensOnFocus || !draft.isEmpty(accepting: accepts.subtracting(.notes))
    }
}

extension View {
    func floatingAbove(@ViewBuilder _ content: () -> some View) -> some View {
        overlay(alignment: .top) {
            Color.clear.frame(height: 0).overlay(alignment: .bottomLeading) { content().padding(.bottom, Spacing.item) }
        }
    }

    func composerNotice(_ shown: Bool, @ViewBuilder _ notice: () -> some View) -> some View {
        floatingAbove {
            if shown {
                VStack(alignment: .leading, spacing: ComposerMetrics.noticeSpacing) { notice() }
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.group).padding(.vertical, ComposerMetrics.noticePadding)
                    .glass(in: .rect(cornerRadius: Radius.card))
                    .allowsHitTesting(false)
            }
        }
    }
}
