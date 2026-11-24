import CueStore
import SwiftUI

struct SubagentList: View {
    let agents: [SubagentState]
    @Environment(\.palette) private var palette
    @State private var expanded = DebugHooks.args.layoutOpts.toolsOpen

    var body: some View {
        if let summary = SubagentSummary(agents) {
            Fold(open: $expanded) {
                header(summary)
            } content: {
                if expanded {
                    NoteThread { ForEach(agents.identified, id: \.id) { row($0.agent).padding(.vertical, Spacing.hair) } }
                }
            }
        }
    }

    private func header(_ summary: SubagentSummary) -> some View {
        NoteLine {
            if summary.running > 0 {
                StateDot(shown: SessionShown(status: .working(.delegating)), size: 6)
            } else {
                Image(.branch).imageScale(.small)
            }
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: Note.spacing) {
                Text(summary.lead).emphasis(summary.running > 0 ? .bold : .regular)
                    .foregroundStyle(summary.running > 0 ? palette.ink : palette.ink3).rollingCount(summary.running > 0 ? summary.running : summary.total)
                if let tail = summary.tail {
                    Dot()
                    Text(tail).foregroundStyle(palette.ink3).rollingCount(summary.total)
                }
                if let failure = summary.failure {
                    Dot().foregroundStyle(palette.failure)
                    Text(failure).foregroundStyle(palette.failure).rollingCount(summary.failed)
                }
                if let rejection = summary.rejection {
                    Dot()
                    Text(rejection).foregroundStyle(palette.ink3).rollingCount(summary.rejected)
                }
                DisclosureChevron(open: expanded)
            }
            .handOff(id: [summary.running > 0 ? "running" : "total", summary.tail == nil ? nil : "total", summary.failure == nil ? nil : "failed", summary.rejection == nil ? nil : "rejected"].compactMap { $0 })
        }
        .accessibilityLabel(Dotted(summary.lead, summary.tail, summary.failure, summary.rejection).spoken)
    }

    private func row(_ agent: SubagentState) -> some View {
        VStack(alignment: .leading, spacing: Spacing.hair) {
            HStack(spacing: Note.spacing) {
                StateDot(shown: agent.shown, size: 6).noteGlyph()
                MetaLine(alignment: .center, spacing: Note.spacing, gap: Spacing.item) {
                    Text("\(Text(agent.name).foregroundStyle(palette.ink2)) \(agent.role)\(agent.model.map { model in Text("\(Dotted.separator)\(BrandMark.label(.model(reference: model), ModelName.short(model)))") } ?? Text(verbatim: ""))")
                        .foregroundStyle(palette.ink3)
                } meta: {
                    if let clock = SubagentClock(agent) { Elapsed(clock: clock) }
                }
            }
            .font(Typography.caption)
            Text("\(Text(agent.label).foregroundStyle(agent.shown.labelTint(palette)))\(Text(agent.action.isEmpty ? "" : "\(Dotted.separator)\(agent.action)").foregroundStyle(palette.ink3))")
                .font(Typography.caption)
                .lineLimit(agent.isRunning ? 1 : nil).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .noteGlyph(.indent)
                .accessibilityLabel(Dotted(agent.label, agent.action).spoken)
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    private struct Elapsed: View {
        let clock: SubagentClock
        @Environment(\.palette) private var palette

        var body: some View {
            Group {
                switch clock {
                case .running(let running): LiveText(style: running.live(.list))
                case .took: Text(clock.text(now: .now))
                }
            }
            .font(Typography.caption).foregroundStyle(palette.ink3)
        }
    }
}
