import CueText
import SwiftUI

extension CuePage {
    /// 一段约几格；屏上那几段上下各留几段真的（`ChatSegments`）。Cue 的回答长、一段要排几十毫秒（真实库），只留一段的话
    /// 来回翻几屏时每拆了又建一段就卡一下；留 `spare` 段时翻动与整段都挂着一样顺，挂着的仍有上限。
    static let segment = 6, spare = 8

    /// `speaker`：这一格是谁的气泡（`CueThread.Row.speaker`），不是气泡为 nil。
    static func gap(before speaker: HorizontalEdge?, joined: Bool) -> CGFloat {
        if joined { return CueBubble.joinedGap }
        return speaker == .trailing ? Spacing.part : Spacing.block
    }

    static let stampAbove = Spacing.block, stampBelow = Spacing.tight

    /// 一批排的是一整块主线程的活（Cue 的回答长，真实库上一屏要一百多毫秒）：批小了打开后那一下不挡点按，离最早那头还不到一屏就接着排（`ChatColumn`）。
    static func paging(_ thread: CueThread) -> ChatPaging {
        let rows = thread.rows
        func count(filling size: CGSize, above: Int) -> Int {
            let column = min(size.width, readingWidth) - 2 * inset
            var sum: CGFloat = 0, count = 0
            for row in rows[..<above].reversed() where sum < size.height {
                sum += floor(row, shots: thread.shots[row.id]?.count ?? 0, joined: thread.joined.contains(row.id), stamped: thread.stamps[row.id] != nil, column: column)
                count += 1
            }
            return max(count, 1)
        }
        return ChatPaging(
            first: { count(filling: CGSize(width: $0.width, height: $0.height - covered(thread, size: $0)), above: $1) },
            step: { min(count(filling: CGSize(width: $0.width, height: $0.height / 2), above: $1), segment) })
    }

    /// Mac 上按输入框（`ComposerMetrics`）、底下的边距与拍板卡（`CueWaitCard.floor`）的下限算，只能数少；
    /// 手机上没算这两样的下限，按整屏数（多排几格，不会铺不满）。
    private static func covered(_ thread: CueThread, size: CGSize) -> CGFloat {
        #if os(macOS)
        let composer = ComposerMetrics.textTop + ComposerMetrics.textBottomOpen + ComposerMetrics.slot
        // 卡与阅读栏同宽（`page` 里回复那一块两边让出同样的边距），至多占对话区的一半
        // 露哪一件随时会换（`Workspace.cueAsking`）：取几件里最矮的，仍只数少
        let floor = thread.waiting.map { CueWaitCard.floor($0, shots: thread.shots, width: min(size.width, readingWidth) - 2 * inset) }.min() ?? 0
        let dock = min(floor, size.height / 2)
        return composer + Spacing.replyBottom + dock
        #else
        0
        #endif
    }

    /// 只能数少、不能数多（数多了第一帧铺不满）；数得越贴，打开时多排的越少。
    private static func floor(_ row: CueThread.Row, shots: Int, joined: Bool, stamped: Bool, column: CGFloat) -> CGFloat {
        let note: CGFloat = 12
        let above = stamped ? stampAbove + note + stampBelow : gap(before: row.speaker, joined: joined)
        let bubble = CueBubble.padding.top + CueBubble.padding.bottom
        func width(_ fraction: CGFloat) -> CGFloat { column * fraction - CueBubble.padding.leading - CueBubble.padding.trailing }
        func said(_ text: String) -> CGFloat {
            TextFloor.plain(CueFormat.plainText(text), width: width(UserBubble<EmptyView>.widthFraction), limit: UserBubble<EmptyView>.foldedLines)
        }
        func answer(_ text: String) -> CGFloat { TextFloor.markdown(text, width: width(CueBubble.cueWidth), spacing: Typography.readingLineSpacing) }
        let body: CGFloat = switch row {
        case .you(let message): bubble + said(message.text)
        case .answer(let question, let quoted): bubble + (quoted ? note + 6 : 0) + said(question.answer ?? "")
        case .cue(let message, _): bubble + answer(message.asking?.question ?? message.text) + (shots == 0 ? 0 : 8 + CueShots.floor(count: shots, width: width(CueBubble.cueWidth)))
        case .result(let message, _):
            bubble + answer(message.text) + 12 + CueShots.floor(count: shots, width: width(CueBubble.cueWidth)) + 12 + CueTaskLine.lineHeight
        case .notes: CueNoteRows.height
        case .process: note
        }
        return above + body
    }
}
