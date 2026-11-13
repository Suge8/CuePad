import CueStore
import SwiftUI

struct CueSegment: View, Equatable {
    let rows: [CueRow]

    @Environment(AppServices.self) private var services

    nonisolated static func == (a: Self, b: Self) -> Bool { a.rows.map(\.key) == b.rows.map(\.key) }

    /// 新到的淡入挂在插进来的那一格上（`equatable()` 外面）：挂在格子里面的过渡不会播。各格用 `equatable()` 包着，带时间的一格也只是一个子视图（`ChatRows` 按一格一个认，`CueRow` 的时间与内容在它自己的竖排里）。
    var body: some View {
        ChatRows(ids: rows.map(\.row.id), spacing: 0) {
            ForEach(rows, id: \.row.id) { row in
                row.equatable().benchSpot(row.row.id).transition(CueRow.arrives(row.row, swapsInPlace: services.cueOnDutyHere) ? CueBubble.arrival : .identity)
            }
        }
    }
}

/// 对话里的一格，连同上面的时间与间距。只按自己的输入比较（`equatable()`）：对话里来了一句、Cue 的状态变了，别的格子不重算——
/// 发出一句的那一刻对话要重排，每格都重算的话那一帧就掉了。"已送达"只交给用得着的那一格。
struct CueRow: View, Equatable {
    let row: CueThread.Row
    let shots: [CueShown]
    let joined: Bool
    let stamp: Date?
    let delivered: Bool
    /// 这一格是新消息：左边一颗小点（`CueUnreadDot`），末尾进出滚动区时报给页面（`CueViewing`）。
    /// 页边距（`chatMargin`）放得下时在气泡外隔一条缝；放不下（iPhone、窄窗口的 iPad）点骑在气泡左缘上（`straddlesDot`），离屏缘约 12 点：
    /// 挤在屏边与气泡之间时离屏缘只剩 3 点，像被切掉一半。
    let unread: Bool
    /// 后面又有了话：醒来那几行收成一行（`CueNoteLog`）。
    let settled: Bool
    @Binding var opened: PreviewOpening?
    @Binding var seen: [UUID: Date]
    @Environment(Workspace.self) private var workspace
    @Environment(\.chatMargin) private var margin

    nonisolated struct Key: Equatable {
        let row: CueThread.Row, shots: [CueShown], joined: Bool, stamp: Date?, delivered: Bool, unread: Bool, settled: Bool
    }

    nonisolated var key: Key {
        Key(row: row, shots: shots, joined: joined, stamp: stamp, delivered: delivered, unread: unread, settled: settled)
    }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.key == b.key }

    /// 时间与内容排进同一个竖排：并列的两个视图在外面的修饰（`equatable()`、`benchSpot`、过渡）下会被叠到同一处。
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let stamp { ChatTimeMarker(date: stamp).padding(.top, CuePage.stampAbove) }
            item
        }
    }

    private var item: some View {
        content
            .overlay(alignment: .topLeading) {
                CueUnreadDot(unread: unread).alignmentGuide(.leading) { [straddlesDot] in
                    straddlesDot ? $0[HorizontalAlignment.center] : $0[.trailing] + CueUnreadDot.gap
                }
            }
            .padding(.top, stamp != nil ? CuePage.stampBelow : CuePage.gap(before: row.speaker, joined: joined))
            .background(alignment: .bottom) {
                if unread {
                    CueEndProbe { visible in seen[row.id] = visible ? row.date : nil }
                }
            }
    }

    /// `swapsInPlace`：Cue 在这台 Mac 值班，它的话原位换下正在说的那句（`CueEnding`），直接出现。你的话由回复框那头的发出动画接上，其余各格直接出现。
    static func arrives(_ row: CueThread.Row, swapsInPlace: Bool) -> Bool {
        switch row {
        case .cue: !swapsInPlace
        case .result: true
        default: false
        }
    }

    @ViewBuilder private var content: some View {
        let cue = workspace.cue
        switch row {
        case .you(let message):
            SpeechBubble(said: .cue(message, host: cue.hostID), box: Bindable(cue).draft, showsDelivered: delivered, look: .cue(joined: joined)) { _ in
                MessageActions(text: message.text, kind: .cue)
            }
        case .answer(let question, let quoted):
            CueAnswer(question: question, quoted: quoted, joined: joined)
        case .cue(let message, let task):
            CueSays(message: message, task: task, shots: shots, open: { opened = $0 }, joined: joined)
        case .result(let message, let task):
            CueSays(message: message, task: task, shots: shots, open: { opened = $0 }, card: true)
        case .notes(let rounds):
            CueNoteLog(rounds: rounds, settled: settled && !unread)
        case .process(_, let touches):
            BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
                CueTrace(touches: touches).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var straddlesDot: Bool { margin < CueUnreadDot.room }
}

/// Cue 此刻在做什么只写在这里，不进对话里的哪一格（经过、醒来那一行都是记录，`CueTrace`），出现、收起与换字都不挪对话。
/// 正在说的话（`CueKeeper.speech`）只有这个视图读它，出字时对话列表不重算；它与对话在同一次更新里拿到同一份对话，落库了（`LiveDraft.landed`）就不再显示，换下是同一帧里的一减一加。
struct CueEnding: View {
    let newestSaid: Date?
    let joined: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            #if os(macOS)
            let draft = services.cue.keeper?.speech.draft
            if let draft, !draft.landed(newestReply: newestSaid, record: nil) {
                // 与落库后的那句（`CueSays`）同一颗气泡、同一个位置，换下时正文不动
                BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
                    MarkdownText(source: draft.text).equatable().cueBubble(joined: joined)
                }
                .padding(.top, CuePage.gap(before: .leading, joined: joined))
                .transition(.asymmetric(insertion: CueBubble.arrival, removal: .identity))
            }
            ChatLiveSlot(gap: CuePage.gap(before: nil, joined: false), font: CueDoing.font, floating: 0) { if draft == nil { live } }
            #else
            ChatLiveSlot(gap: CuePage.gap(before: nil, joined: false), font: CueDoing.font, floating: 0) { live }
            #endif
        }
    }

    @ViewBuilder private var live: some View {
        let presence = workspace.cue.presence
        if let shown = presence.shown, let progress = presence.progress {
            CueDoing(shown: shown, doing: progress)
                .transition(.asymmetric(insertion: .entry, removal: .identity))
        }
    }
}

private struct CueDoing: View {
    let shown: SessionShown
    let doing: String
    @Environment(\.palette) private var palette

    static let font = Typography.secondary

    var body: some View {
        NoteLine { StateDot(shown: shown, size: 7) } label: {
            DoingLine(text: doing).font(Self.font).foregroundStyle(palette.ink2).lineLimit(1)
        }
        .accessibilityElement(children: .ignore).accessibilityLabel(doing)
    }
}
