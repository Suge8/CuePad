import CueStore
import CueText
import SwiftUI

/// 连着的几轮 Cue 自己醒来（`CueThread.Row.notes`）：每轮一行旁注，不画框、不铺底（对话里只有说的话是一块，`Note`）。
/// 要你拍板的不在这里：在输入框上方的拍板卡里（`CueWaitDock`），这里只留一句发生过什么。
/// 一行从左到右：图标、字、几点（等宽一列，对齐）。一行是一条记录，定格在写下那一刻：图标与字只按记录画（`CueWakeHeader`），
/// 那一处之后改名、再动起来都不变；只有在跑的那一轮挂着的经过末行在动，这一轮结束就定格。
/// - 图标：提到一处时是当时出了什么事（`CueChange.Kind.icon`，静止的），提到几处或没提到哪处时是醒来原因（`CueWake.icon`）。
/// - 字：当时的名字（次要墨，几处时用顿号连起）与当时出了什么事，逗号后接它这一轮说的话，截成一行，其余淡墨；没提到哪处的写它说的话或为什么醒。
/// 整行是一行（`RowStyle`），点了去提到的那一处（会话直接进；几处时列出来选；提醒去记忆）；没提到哪处的不能点。
/// 在跑的那一轮下面挂这一轮的经过（`CueTrace`：碰到的各处与此刻在做的），与这几行同一种行（`CueNoteRow`）。
/// 多于 `foldAfter` 轮时只露最近 `shownWhenFolded` 轮，上面一行"更早还醒过 N 次"，点它全部展开。左缘对着 Cue 气泡的左缘（同 `CueTrace`）。
struct CueNoteLog: View {
    let rounds: [CueNoteRound]
    /// 在跑的那一轮在这几轮里时有（`CueLiveRound`）
    let live: CueLiveRound?
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
                ForEach(shown) { round in CueNoteLine(round: round, live: live) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.entry)
    }
}

/// 一轮一行，在跑的那一轮下面挂这一轮的经过。
private struct CueNoteLine: View {
    let round: CueNoteRound
    let live: CueLiveRound?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let places = round.header?.places ?? []
        VStack(alignment: .leading, spacing: 0) {
            link(places, row: CueNoteRow(time: round.date) { glyph(places) } text: { line(places) })
            if let row = round.row, let live, row.id == live.round {
                CueTrace(touches: round.touches, doing: live.doing)
            }
        }
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

    private func glyph(_ places: [CueWakeHeader.Place]) -> Image {
        if places.count == 1, let kind = places[0].kind { return Image(kind.icon) }
        return Image(round.header?.wake.icon ?? .said)
    }

    private func line(_ places: [CueWakeHeader.Place]) -> Text {
        let said = round.said.isEmpty ? nil : round.said.map { CueFormat.plainText($0.text) }.joined(separator: " ")
        let head: Text? = switch places.count {
        case 0: nil
        case 1: place(places[0])
        default: Text("\(Text(places.map(\.title).formatted(.list(type: .and))).foregroundStyle(palette.ink2)) 有动静")
        }
        let tail = said ?? (head == nil ? round.header?.wake.reason : nil)
        return switch (head, tail) {
        // 接在一处后面的那句（Cue 说的或醒来原因）自成一键：英文用冒号接整句，不与别处并列两段的"%@，%@"共用
        case (let head?, let tail?): Text("\(head)\(Text("，\(tail)", comment: "Cue 页醒来那一行：一处之后接 Cue 说的话"))")
        case (let head?, nil): head
        case (nil, let tail?): Text(tail)
        case (nil, nil): Text("")
        }
    }

    /// 一处：名字，当时出了事时接一句（"登录回调 停下了"）。
    private func place(_ place: CueWakeHeader.Place) -> Text {
        let title = Text(place.title).foregroundStyle(palette.ink2)
        return place.kind.map { Self.line(title, $0) } ?? title
    }

    /// 一处当时出了什么事的整句（名字带着样式插进去）。
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

/// Cue 页的一行旁注（醒来那几行、一轮的经过 `CueTrace` 共用）：图标、截成一行的字，醒来那几行行末是等宽的几点（一列对齐）。
struct CueNoteRow<Glyph: View, Words: View>: View {
    var time: Date?
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let text: Words
    @Environment(\.palette) private var palette

    var body: some View {
        let words = text.foregroundStyle(palette.ink3).lineLimit(1)
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            glyph.foregroundStyle(palette.ink3).noteGlyph().accessibilityHidden(true)
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
    /// 一行至少多高：比旁注（`Note.lineHeight`）高一点，整行可点。
    static let height: CGFloat = Note.lineHeight + 4
}
