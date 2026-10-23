import CueStore
import CueText
import SwiftUI

/// 连着的几轮 Cue 自己醒来（`CueThread.Row.notes`）：每轮一行旁注，不画框、不铺底（对话里只有说的话是一块，`ChatMargin`）。
/// 要你拍板的不在这里：在输入框上方的等你卡里（`CueWaitDock`），这里只留一句发生过什么。
/// 一行从左到右：图标、字、几点（等宽一列，对齐）。
/// - 图标：提到一处时是那一处此刻的样子（会话的状态标 `PiStateDot`、任务圈），与当时出了什么事分开——当时"停下了"的会话此刻可能又在跑；
///   提到几处或没提到哪处时是醒来原因（`CueWake.icon`）。
/// - 字：名字（次要墨，几处时用顿号连起）与当时出了什么事，后面隔一个点接它这一轮说的话，截成一行，其余淡墨；没提到哪处的写它说的话或为什么醒。
/// 整行是一行（`RowStyle`），点了去提到的那一处（会话直接进；几处时列出来选；提醒去记忆）；没提到哪处的不能点。
/// 在跑的那一轮下面挂此刻在做的（`RoundProcess`）。多于 `foldAfter` 轮时只露最近 `shownWhenFolded` 轮，上面一行"更早还醒过 N 次"，点它全部展开。
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
                        CueNoteRow(time: nil) { Image(.earlier) } text: { Text("更早还醒过 \(rounds.count - shown.count) 次") }
                    }
                    .buttonStyle(.row)
                }
                ForEach(shown) { round in CueNoteLine(round: round, live: live) }
            }
            .padding(.leading, CueBubble.noteInset)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .transition(.entry)
    }
}

/// 一轮一行，在跑的那一轮下面挂此刻在做的。
private struct CueNoteLine: View {
    let round: CueNoteRound
    let live: CueLiveRound?
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    var body: some View {
        let places = round.header?.places ?? []
        VStack(alignment: .leading, spacing: 0) {
            link(places, row: CueNoteRow(time: round.date) { glyph(places) } text: { line(places) })
            if let row = round.row, row.id == live?.round {
                RoundProcess(tools: row.tools, ending: CueLiveRound.ending(of: row, in: live)).padding(.leading, CueNoteRows.textInset)
            }
        }
    }

    @ViewBuilder private func link(_ places: [CueWakeHeader.Place], row: some View) -> some View {
        let targets = places.compactMap { place in place.target.map { (title: place.title, target: $0) } }
        switch targets.count {
        case 0: row
        case 1: Button { workspace.open(targets[0].target) } label: { row }.buttonStyle(.row)
        default:
            Menu {
                ForEach(targets, id: \.title) { place in Button(place.title) { workspace.open(place.target) } }
            } label: { row }
            .menuStyle(.button).buttonStyle(.row).menuIndicator(.hidden)
        }
    }

    @ViewBuilder private func glyph(_ places: [CueWakeHeader.Place]) -> some View {
        if places.count == 1, let id = places[0].sessionID {
            PiStateDot(shown: workspace.liveShown(sessionID: id) ?? PiShown(status: .ended), size: 6)
        } else if places.count == 1, places[0].kind != nil, places[0].sessionID == nil {
            TaskRingView(status: places[0].task, done: false, size: 11)
        } else {
            Image(round.header?.wake.icon ?? RoundProcess.icon(.said))
        }
    }

    private func line(_ places: [CueWakeHeader.Place]) -> Text {
        let said = round.said.isEmpty ? nil : round.said.map { CueFormat.plainText($0.text) }.joined(separator: " ")
        let head: Text? = switch places.count {
        case 0: nil
        case 1: Text("\(Text(places[0].title).foregroundStyle(palette.ink2))\(places[0].kind.map { " " + CueWakeHeader.verb($0) } ?? "")")
        default: Text("\(Text(places.map(\.title).joined(separator: "、")).foregroundStyle(palette.ink2)) 有动静")
        }
        let tail = said ?? (head == nil ? round.header?.wake.reason : nil)
        return switch (head, tail) {
        case (let head?, let tail?): Text("\(head)\(Dotted.separator)\(tail)")
        case (let head?, nil): head
        case (nil, let tail?): Text(tail)
        case (nil, nil): Text("")
        }
    }
}

/// 一行旁注：图标、截成一行的字、等宽的几点（一列对齐）。
private struct CueNoteRow<Glyph: View, Words: View>: View {
    let time: Date?
    @ViewBuilder let glyph: Glyph
    @ViewBuilder let text: Words
    @Environment(\.palette) private var palette

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
            glyph.foregroundStyle(palette.ink3).frame(width: Note.glyphWidth).accessibilityHidden(true)
            text.foregroundStyle(palette.ink3).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
            Text(time.map(ChatTime.time) ?? "").monospacedDigit().foregroundStyle(palette.ink3)
                .frame(minWidth: CueNoteRows.timeWidth, alignment: .trailing).fixedSize()
        }
        .font(Typography.caption)
        .frame(minHeight: CueNoteRows.height)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
    }
}

enum CueNoteRows {
    /// 字的左缘：图标位与间距（在跑的那一轮挂的那一行对着它）。
    static let textInset = Note.glyphWidth + Note.spacing
    /// 几点那一列至少多宽："中午 12:44" 放得下，一列对齐。
    static let timeWidth: CGFloat = 62
    /// 一行至少多高：比旁注（`Note.lineHeight`）高一点，整行可点。
    static let height: CGFloat = Note.lineHeight + 4
}

extension Workspace {
    /// 去 Cue 自己醒来那一轮提到的那一处：会话、任务（从点的地方长出气泡）或记忆。
    func open(_ target: CueWakeHeader.Target) {
        switch target {
        case .session(let session): openSession(session.id, sessionID: session.sessionID)
        case .task(let id): openTask(id: id)
        case .memory: cue.showsMemory = true
        }
    }

    /// 在线会话此刻的样子（`shown`）；已结束、不在了为 nil。
    func liveShown(sessionID: String) -> PiShown? {
        services.liveSessions.items.first { $0.state.sessionID == sessionID }.map(shown)
    }
}
