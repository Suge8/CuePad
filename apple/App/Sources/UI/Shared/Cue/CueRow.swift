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

struct CueRow: View, Equatable {
    let row: CueThread.Row
    let shots: [CueShown]
    let joined: Bool
    let stamp: Date?
    let delivered: Bool
    let unread: Bool
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
                CueTrace(touches: touches).frame(maxWidth: .infinity, alignment: .leading).onSky()
            }
        }
    }

    private var straddlesDot: Bool { margin < CueUnreadDot.room }
}

extension View {
    /// 天空上读不清的一块（经过、动静）垫一层玻璃；气泡自己有底，不再垫。
    func onSky() -> some View {
        padding(.vertical, Spacing.tight).padding(.horizontal, Spacing.item).glass(in: .rect(cornerRadius: Radius.sheet))
    }
}

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
                BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
                    MarkdownText(source: draft.text).equatable().cueBubble(joined: joined)
                }
                .padding(.top, CuePage.gap(before: .leading, joined: joined))
                .transition(.asymmetric(insertion: CueBubble.arrival, removal: .identity))
            }
            ChatLiveSlot(gap: CuePage.gap(before: nil, joined: false), font: Typography.secondary, floating: 0) { figure(speaking: draft != nil) }
            #else
            ChatLiveSlot(gap: CuePage.gap(before: nil, joined: false), font: Typography.secondary, floating: 0) { figure(speaking: false) }
            #endif
        }
    }

    private func figure(speaking: Bool) -> some View {
        LiveFigure(live: speaking ? nil : FigureLive(cue: workspace.cue.presence, now: workspace.cue.now), handoff: FigureHandoff(reply: newestSaid, speaking: speaking))
    }
}
