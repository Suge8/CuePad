import CueStore
import CueText
import SwiftUI

extension CuePage {
    /// 一段约几格；屏上那几段上下各留几段真的（`ChatSegments`）。Cue 的回答长、一段要排几十毫秒（真实库），只留一段的话
    /// 来回翻几屏时每拆了又建一段就卡一下；留八段时翻动与整段都挂着一样顺，挂着的仍有上限。
    static let segment = 6, spare = 8

    /// 一格上面空多少：同一边连着说的收成一串，你开始说的新一轮与上一轮拉开，其余（Cue 接你的话、经过、动态、分隔）是一般的间距。
    /// `speaker`：这一格是谁的气泡（`CueThread.Row.speaker`），不是气泡为 nil。
    static func gap(before speaker: HorizontalEdge?, joined: Bool) -> CGFloat {
        if joined { return CueBubble.joinedGap }
        return speaker == .trailing ? 24 : 16
    }

    /// 隔了一阵写时间的那一格：时间上面空多少、时间与这一格之间空多少（`ChatTimeMarker`；排的与估高的同用这两个）。
    static let stampAbove: CGFloat = 16, stampBelow: CGFloat = 4

    /// 打开与往上翻都铺一屏（`conversation`），按每格至少多高（`floor`）从下往上数，只算数到的那几格；打开时最新处停在浮着的那一块上方，
    /// 只铺它上面那一截（`covered`）。
    static func paging(_ thread: CueThread) -> ChatPaging {
        let rows = thread.rows
        func count(filling size: CGSize, above: Int) -> Int {
            // 阅读栏（可见区里去掉两边的边距，`ChatLayout.margin`）
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
            step: { count(filling: $0, above: $1) })
    }

    /// 浮在对话底上的那一块（`bottom`）至少多高：对话底下让出它那么高的留白（`chatBottomInset`），最新处停在它上方。
    /// Mac 上按输入框（`ComposerMetrics`）、底下的边距与"等你"卡（`CueWaitingDock.floor`）的下限算，只能数少；
    /// 手机上没算这两样的下限，按整屏数（多排几格，不会铺不满）。
    private static func covered(_ thread: CueThread, size: CGSize) -> CGFloat {
        #if os(macOS)
        let composer = ComposerMetrics.textTop + ComposerMetrics.textBottomOpen + ComposerMetrics.slot
        // 卡与阅读栏同宽（`page` 里回复那一块两边让出同样的边距），至多占对话区的一半
        // 露哪一条可能被换到最前（`Workspace.leadingAsk`）：取几条里最矮的，仍只数少
        let floor = thread.waiting.map { CueWaitingDock.floor($0, shots: thread.shots, width: min(size.width, readingWidth) - 2 * inset) }.min() ?? 0
        let dock = min(floor, size.height / 2)
        return composer + replyPadding + dock
        #else
        0
        #endif
    }

    /// 一格至少多高（连同上面的间距与时间）：气泡里的字至少多高（`TextFloor`），点名了图的提问与结果卡另有图（`shots` 张，`CueShots.floor`），
    /// 结果卡还有下面那件活一行，旁注、经过与分隔至少一行小字（`note`），动态的虚线气泡里至少一行。
    /// 只能数少、不能数多（数多了第一帧铺不满）；数得越贴，打开时多排的越少。
    private static func floor(_ row: CueThread.Row, shots: Int, joined: Bool, stamped: Bool, column: CGFloat) -> CGFloat {
        let note: CGFloat = 12
        let above = stamped ? stampAbove + note + stampBelow : gap(before: row.speaker, joined: joined)
        let bubble = CueBubble.padding.top + CueBubble.padding.bottom
        // 气泡里字排开的宽：气泡最宽占阅读栏的那一份，去掉内边距（`BubbleWidth`）
        func width(_ fraction: CGFloat) -> CGFloat { column * fraction - CueBubble.padding.leading - CueBubble.padding.trailing }
        func said(_ text: String) -> CGFloat {
            TextFloor.plain(CueFormat.plainText(text), width: width(UserBubble<EmptyView>.widthFraction), limit: UserBubble<EmptyView>.foldedLines)
        }
        func answer(_ text: String) -> CGFloat { TextFloor.markdown(text, width: width(CueBubble.cueWidth), spacing: Typography.readingLineSpacing) }
        let body: CGFloat = switch row {
        case .you(let message): bubble + said(message.text)
        // 引用那一行至少一行小字，下面是回答
        case .answer(let question): bubble + note + 6 + said(question.answer ?? "")
        // 字与图之间隔 8（`CueSays`）
        case .cue(let message, _): bubble + answer(message.text) + (shots == 0 ? 0 : 8 + CueShots.floor(count: shots, width: width(CueBubble.cueWidth)))
        // 字、图与那件活（至少 `CueTaskLine` 那么高）之间各隔 12
        case .result(let message, _):
            bubble + answer(message.text) + 12 + CueShots.floor(count: shots, width: width(CueBubble.cueWidth)) + 12 + CueTaskLine.lineHeight
        // 虚线气泡至少一行小字
        case .notes: bubble + note
        case .process, .renewed: note
        }
        return above + body
    }
}
