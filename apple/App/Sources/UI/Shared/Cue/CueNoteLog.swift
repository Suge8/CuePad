import CueStore
import CueText
import SwiftUI

/// 要你拍板的不在这里：在输入框上方的拍板卡里（`CueWaitDock`），这里只留一句发生过什么。
/// 连着的几轮（中间没人说话）排成一块，一处一行（`CueNoteFold`）：同一个会话停下十几次是一行带次数，不是十几行。
/// 字定格在写下那一刻：图标与字只按记录画（`CueWakeHeader`、`CueMessage.tools`），那一处之后改名、再动起来都不变；这一轮此刻在做什么只写在对话末尾那一行（`CueEnding`）。
/// Cue 这一轮不写话（系统提示「说话」），去处只从动作推出，三处说同一套话。
/// 后面又有了话的那几块是旧事（`settled`）：几行收成一行（哪几处、最近那次几点），点开才逐行列；对话最末那一块与还没读的照旧逐行，那是此刻的事。
struct CueNoteLog: View {
    let rounds: [CueNoteRound]
    let settled: Bool
    @State private var unfolded = DebugHooks.preset.toolsOpen
    @Environment(\.palette) private var palette

    var body: some View {
        let folds = CueNoteFold.folds(rounds)
        let newest = Self.newest(folds)
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: 0) {
                if settled, !unfolded, folds.count > 1 {
                    Button { unfolded = true } label: {
                        CueNoteRow(time: folds.last?.last.date) { Image(.expand) } text: { summary(folds) }
                    }
                    .buttonStyle(.row)
                    .accessibilityHint("展开")
                } else {
                    ForEach(folds) { fold in CueNoteLine(fold: fold, newest: newest.contains(fold.id)) }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .animation(Motion.fade, value: folds)
        }
        .transition(.entry)
    }

    /// 名字取最近有动静的那一处。
    private func summary(_ folds: [CueNoteFold]) -> Text {
        var names: [String] = []
        for place in folds.reversed().flatMap({ $0.last.header?.places ?? [] }) where !names.contains(place.title) { names.append(place.title) }
        let name = Text(names.first ?? "").foregroundStyle(palette.ink2)
        return switch names.count {
        case 0: Text("\(folds.count) 条动静")
        case 1: Text("\(name) 有 \(folds.count) 条动静")
        default: Text("\(name) 等 \(names.count) 处有动静")
        }
    }

    private static func newest(_ folds: [CueNoteFold]) -> Set<CueNoteFold.ID> {
        var seen = Set<CueWakeHeader.Target>(), out = Set<CueNoteFold.ID>()
        for fold in folds.reversed() {
            guard let places = fold.last.header?.places, places.count == 1 else { continue }
            if seen.insert(places[0].target).inserted { out.insert(fold.id) }
        }
        return out
    }
}

private struct CueNoteLine: View {
    let fold: CueNoteFold
    let newest: Bool
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    private var round: CueNoteRound { fold.last }

    var body: some View {
        let places = round.header?.places ?? []
        link(places, row: CueNoteRow(time: round.date, tint: tint(places)) { glyph(places) } text: { words(places) })
    }

    /// 放不下时先收短名字：去处与次数在句尾，整句截断会先丢掉它们。
    private func words(_ places: [CueWakeHeader.Place]) -> some View {
        ViewThatFits(in: .horizontal) {
            counted(line(places)).fixedSize()
            if places.count == 1 {
                counted(line(places.map { $0.titled($0.title.clipped(14)) })).fixedSize()
                counted(line(places.map { $0.titled($0.title.clipped(8)) }))
            }
        }
    }

    private func counted(_ line: Text) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tight) {
            line
            if fold.rounds.count > 1 {
                Dot()
                Text("\(fold.rounds.count) 次").monospacedDigit().fixedSize().contentTransition(.numericText())
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
                    Text(verbatim: [ChatTime.day(time), ChatTime.time(time)].compactMap { $0 }.joined(separator: " "))
                        .monospacedDigit().foregroundStyle(palette.ink3)
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
