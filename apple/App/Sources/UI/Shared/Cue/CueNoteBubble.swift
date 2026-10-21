import CueStore
import CueText
import SwiftUI

/// 连着的几轮 Cue 自己醒来（`CueThread.Row.notes`）：靠左的一颗虚线气泡，形状同 Cue 的气泡（`CueBubble.shape`），只描边不铺底——
/// 是它说的话，但没推给你，与纸做的实底气泡（对你说的）一眼分开。每轮一节（`CueNoteSection`）：第一行为什么醒与几点，下面是它说的话（小一档的次要墨色），
/// 调过工具的再一行经过（`RoundProcess`，设置里关了工具步骤时没有；在跑的那一轮总有，写此刻在做的）。做完了、只看了看、没说话的一轮只占一行"…… · 没动手"，
/// 连着几次并成一行"看了 N 次，都没动手"；在跑的那一轮还不算（它随时会动手、说话，算了就要在并起来与分开之间来回跳）。
/// 超过 `foldAfter` 节时只露最近 `shownWhenFolded` 节，上面一行"更早还醒过 N 次"，点它或点并起来的那一行原地全部展开（各节分开列）。
struct CueNoteBubble: View {
    let rounds: [CueNoteRound]
    /// 在跑的那一轮在这几节里时有（`CueLiveRound`）
    let live: CueLiveRound?
    @State private var expanded = DebugHooks.preset.toolsOpen
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 多于这么多节（并起来的没动手算一节）才折
    static let foldAfter = 4
    static let shownWhenFolded = 3

    /// 气泡里的一节：一轮，或连着几轮没动手的并成的一行。
    enum Unit: Identifiable {
        case round(CueNoteRound)
        case quiet([CueNoteRound])

        var id: UUID {
            switch self {
            case .round(let round): round.id
            case .quiet(let rounds): rounds[0].id
            }
        }

        var count: Int {
            switch self {
            case .round: 1
            case .quiet(let rounds): rounds.count
            }
        }
    }

    var body: some View {
        let units = expanded ? rounds.map(Unit.round) : Self.merged(rounds, live: live?.round)
        let folded = !expanded && units.count > Self.foldAfter
        let shown = folded ? Array(units.suffix(Self.shownWhenFolded)) : units
        BubbleWidth(fraction: CueBubble.cueWidth, edge: .leading) {
            VStack(alignment: .leading, spacing: Self.sectionGap) {
                if folded {
                    let earlier = units.dropLast(Self.shownWhenFolded).reduce(0) { $0 + $1.count }
                    Button { expanded = true } label: {
                        NoteLine(icon: .earlier) { Text("更早还醒过 \(earlier) 次") }
                    }
                    .buttonStyle(.plain)
                }
                ForEach(shown) { unit in
                    switch unit {
                    case .round(let round): CueNoteSection(round: round, live: live)
                    case .quiet(let rounds):
                        // 图标与几点是最近那次的
                        Button { expanded = true } label: {
                            NoteLine(icon: rounds[rounds.count - 1].header?.wake.icon ?? .wakeIdle, open: false, time: rounds[rounds.count - 1].date) {
                                Text("看了 \(rounds.count) 次")
                                Dot().foregroundStyle(palette.ink3)
                                Text("都没动手")
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(CueBubble.padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background { CueBubble.shape(.leading).strokeBorder(palette.noteEdge, style: StrokeStyle(lineWidth: 1, dash: [4, 3])) }
            .contentShape(CueBubble.shape(.leading))
        }
        .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
        .transition(.entry)
    }

    #if os(macOS)
    static let sectionGap: CGFloat = 12
    #else
    static let sectionGap: CGFloat = 14
    #endif

    /// 连着几轮没动手并成一节；只有一轮的照常一节。
    static func merged(_ rounds: [CueNoteRound], live: UUID?) -> [Unit] {
        var units: [Unit] = [], run: [CueNoteRound] = []
        func flush() {
            if run.count == 1 { units.append(.round(run[0])) } else if !run.isEmpty { units.append(.quiet(run)) }
            run = []
        }
        for round in rounds {
            if round.quiet(live: live) { run.append(round) } else {
                flush()
                units.append(.round(round))
            }
        }
        flush()
        return units
    }
}

/// 虚线气泡里的一轮：为什么醒（`CueWakeTitle`），它说的话，调过工具的一行经过。旧的动态没有醒来原因，只有说的话。
private struct CueNoteSection: View {
    let round: CueNoteRound
    let live: CueLiveRound?
    @Environment(\.palette) private var palette

    var body: some View {
        let indent = round.header == nil ? 0 : Note.glyphWidth + Note.spacing
        // 只有图标的第一行（没有名字）把第一句话接在图标后面，不空占一行
        let inline = round.header?.name == nil ? round.said.first : nil
        VStack(alignment: .leading, spacing: 3) {
            if let header = round.header {
                CueWakeTitle(header: header, at: round.date, quiet: round.quiet(live: live?.round), said: inline.map { CueFormat.plainText($0.text) })
            }
            ForEach(inline == nil ? round.said : Array(round.said.dropFirst())) { note in
                Text(CueFormat.plainText(note.text)).font(Typography.secondary).foregroundStyle(palette.ink2)
                    .lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, indent)
            if let row = round.row, row.tools != nil || row.id == live?.round {
                RoundProcess(tools: row.tools, ending: CueLiveRound.ending(of: row, in: live)).padding(.leading, indent)
            }
        }
    }
}
