import CueText
import SwiftUI

extension CuePage {
    static let segment = 6, spare = 8

    static func gap(before speaker: HorizontalEdge?, joined: Bool) -> CGFloat {
        if joined { return CueBubble.joinedGap }
        return speaker == .trailing ? Spacing.part : Spacing.block
    }

    static let stampAbove = Spacing.block, stampBelow = Spacing.tight

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
            first: { count(filling: CGSize(width: $0.width, height: $0.height - covered), above: $1) },
            step: { min(count(filling: CGSize(width: $0.width, height: $0.height / 2), above: $1), segment) })
    }

    private static var covered: CGFloat {
        #if os(macOS)
        ComposerMetrics.textTop + ComposerMetrics.textBottomOpen + ComposerMetrics.slot + Spacing.replyBottom
        #else
        0
        #endif
    }

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
        case .cue(let message, _): bubble + answer(message.text) + (shots == 0 ? 0 : 8 + CueShots.floor(count: shots, width: width(CueBubble.cueWidth)))
        case .result(let message, _):
            bubble + answer(message.text) + 12 + CueShots.floor(count: shots, width: width(CueBubble.cueWidth)) + 12 + CueTaskLine.lineHeight
        case .notes: CueNoteRows.height
        case .process: note
        }
        return above + body
    }
}
