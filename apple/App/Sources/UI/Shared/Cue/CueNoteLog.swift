import CueStore
import CueText
import SwiftUI

/// 要你拍板的不在这里：在输入框上方的拍板卡里（`CueWaitDock`），这里只留一句发生过什么。
/// 一行是一条记录，定格在写下那一刻：图标与字只按记录画（`CueWakeHeader`、`CueMessage.tools`），那一处之后改名、再动起来都不变；这一轮此刻在做什么只写在对话末尾那一行（`CueEnding`）。
/// Cue 这一轮不写话（系统提示「说话」），去处只从动作推出，三处说同一套话。
struct CueNoteLog: View {
    let rounds: [CueNoteRound]
    @State private var expanded = DebugHooks.preset.toolsOpen

    static let foldAfter = 6
    static let shownWhenFolded = 5

    var body: some View {
        let folded = !expanded && rounds.count > Self.foldAfter
        let shown = folded ? Array(rounds.suffix(Self.shownWhenFolded)) : rounds
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                if folded {
                    Button { expanded = true } label: {
                        CueNoteRow { Image(.earlier) } text: { Text("更早还醒过 \(rounds.count - shown.count) 次") }
                    }
                    .buttonStyle(.row)
                }
                let newest = Self.newest(shown)
                ForEach(shown) { round in CueNoteLine(round: round, newest: newest.contains(round.id)) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.entry)
    }

    private static func newest(_ rounds: [CueNoteRound]) -> Set<CueNoteRound.ID> {
        var seen = Set<CueWakeHeader.Target>(), out = Set<CueNoteRound.ID>()
        for round in rounds.reversed() {
            guard let places = round.header?.places, places.count == 1 else { continue }
            if seen.insert(places[0].target).inserted { out.insert(round.id) }
        }
        return out
    }
}

private struct CueNoteLine: View {
    let round: CueNoteRound
    let newest: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let places = round.header?.places ?? []
        link(places, row: CueNoteRow(time: round.date, tint: tint(places)) { glyph(places) } text: { line(places) })
    }

    @ViewBuilder private func link(_ places: [CueWakeHeader.Place], row: some View) -> some View {
        switch places.count {
        case 0: row
        case 1: Button { workspace.open(places[0].target) } label: { row }.buttonStyle(.row)
        default:
            Menu {
                ForEach(places, id: \.title) { place in Button(place.title) { workspace.open(place.target) } }
            } label: { row }
            .menuStyle(.button).buttonStyle(.row).menuIndicator(.hidden)
        }
    }

    private func tint(_ places: [CueWakeHeader.Place]) -> Color? {
        guard newest, places.count == 1, let kind = places[0].kind, case .session(_, let id?) = places[0].target,
              let item = workspace.services.liveSessions.live.first(where: { $0.state.sessionID == id }),
              kind.isUnresolved(workspace.shown(item).status, session: item.state, since: round.date) else { return nil }
        return kind.openTint(palette)
    }

    private func glyph(_ places: [CueWakeHeader.Place]) -> Image {
        if let outcome = round.outcome { return Image(CueTrace.icon(outcome.kind)) }
        if places.count == 1, let kind = places[0].kind { return Image(kind.icon) }
        return Image(round.header?.wake.icon ?? .wakeActivity)
    }

    private func line(_ places: [CueWakeHeader.Place]) -> Text {
        let head: Text? = switch places.count {
        case 0: nil
        case 1: place(places[0])
        default: Text("\(Text(places[0].title).foregroundStyle(palette.ink2)) 等 \(places.count) 处有动静")
        }
        let tail: Text? = if let outcome = round.outcome {
            places.count == 1 ? places[0].settled(by: outcome).map(Self.outcome) ?? CueTrace.words(outcome, name: palette.ink2)
                : CueTrace.words(outcome, name: palette.ink2)
        } else {
            head == nil ? round.header.map { Text($0.wake.reason) } : nil
        }
        return switch (head, tail) {
        // 接在前半句后面的去处自成一键：英文用冒号接，不与别处并列两段的"%@，%@"共用
        case (let head?, let tail?): Text("\(head)\(Text("，\(tail)", comment: "Cue 页醒来那一行：发生了什么之后接 Cue 定的去处"))")
        case (let head?, nil): head
        case (nil, let tail?): tail
        case (nil, nil): Text("")
        }
    }

    private static func outcome(_ kind: ChatMessage.Tools.Kind) -> Text {
        switch kind {
        case .leave: Text("留给你")
        case .done: Text("做完了")
        case .stop: Text("收掉了")
        default: Text("让它继续")
        }
    }

    private func place(_ place: CueWakeHeader.Place) -> Text {
        let title = Text(place.title).foregroundStyle(palette.ink2)
        if let missed = place.missed { return Text("\(title)，\(ScheduleText.missed(missed))") }
        return place.kind.map { Self.line(title, $0) } ?? title
    }

    private static func line(_ title: Text, _ kind: CueChange.Kind) -> Text {
        switch kind {
        case .settled: Text("\(title) 停下了")
        case .waitingForUser: Text("\(title) 在等回答")
        case .failed: Text("\(title) 出错了")
        case .undelivered: Text("\(title) 话没送到")
        case .done: Text("\(title) 做完了")
        case .stalled: Text("\(title) 子代理卡住了")
        }
    }
}

/// 醒来那几行、一轮的经过（`CueTrace`）共用。
struct CueNoteRow<Glyph: View, Words: View>: View {
    var time: Date?
    var tint: Color?
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let text: Words
    @Environment(\.palette) private var palette

    var body: some View {
        let words = text.foregroundStyle(palette.ink3).lineLimit(1)
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            glyph.foregroundStyle(tint ?? palette.ink3).readerHidden(true).noteGlyph()
            if let time {
                MetaLine(gap: Note.spacing) {
                    words
                } meta: {
                    Text(ChatTime.time(time)).monospacedDigit().foregroundStyle(palette.ink3)
                        .frame(minWidth: CueNoteRows.timeWidth, alignment: .trailing)
                }
            } else {
                words.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(Typography.caption)
        .frame(minHeight: CueNoteRows.height)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

enum CueNoteRows {
    /// 几点那一列至少多宽："中午 12:44" 放得下，一列对齐。
    static let timeWidth: CGFloat = 62
    static let height: CGFloat = Note.lineHeight + 4
}

extension CueChange.Kind {
    func openTint(_ palette: Palette) -> Color {
        self == .waitingForUser ? palette.waiting : palette.failure
    }
}
