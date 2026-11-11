import SwiftUI

enum ComposerMetrics {
    static let inset: CGFloat = 8
    static let slot: CGFloat = 56
    static let textTop: CGFloat = 17
    static let textBottomOpen: CGFloat = 4
    static let glyph: CGFloat = 40
    static let glyphTarget: CGFloat = 44
    static let noticeSpacing: CGFloat = 4
    static let noticePadding: CGFloat = 8
    /// 会话页对话末尾按动态字号缩放它（`Conversation`），外边距不缩放。
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

    /// 只留这一版里问过、撑满过上限的，别的作废：动画里一帧一个宽度，不留着越攒越多。
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

/// 一个输入框一个值，调用方按场景给。
enum ComposerForm: Equatable {
    /// 一直是两层、工具排一直在：浮起的输入框（新会话、交给 Agent）、Mac 菜单栏面板、Mac 会话回复框。
    case open
    /// 空着又没聚焦时收成一行；有内容时两层，`opensOnFocus` 时聚焦也展开（Mac 底部输入栏；手机会话回复框：
    /// 有工具排时聚焦就展开，已结束的会话没有工具，聚焦了也保持一行，打了字再长）。
    case line(opensOnFocus: Bool)
    /// 没聚焦时收成短胶囊（＋ 与一行提示，有草稿写"草稿：第一行"），点它聚焦后同 `line`（手机会话页在看历史时）。
    case capsule(opensOnFocus: Bool)

    var opensOnFocus: Bool {
        switch self {
        case .open: true
        case .line(let opens), .capsule(let opens): opens
        }
    }

    var isCapsule: Bool { if case .capsule = self { true } else { false } }
}

extension View {
    /// 不进排版：挂在上沿一条零高的线上，叠放的东西多高都不改这一块的高。排进来的话它一出一收这一块就当帧变高变矮，浮在它上面的对话跟着跳；对话页上盖住的是对话末尾常驻那一行的位置（`ChatLiveSlot` 按它的高让出），不是内容。
    func floatingAbove(@ViewBuilder _ content: () -> some View) -> some View {
        overlay(alignment: .top) {
            Color.clear.frame(height: 0).overlay(alignment: .bottomLeading) { content().padding(.bottom, Spacing.item) }
        }
    }

    /// 只是说明、不接点按：后面的对话照常滚、照常点。
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
