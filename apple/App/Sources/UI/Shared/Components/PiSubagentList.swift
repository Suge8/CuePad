import CueStore
import SwiftUI

/// 会话页对话末尾的子代理：一行汇总"2 个在跑 · 共 8 个 · 1 失败"——在跑的个数是主句、用正文墨色，共几个是次句、退成次要墨色
/// （有在跑的时前面是转着的状态标；都停了只写"8 个子代理"，整行退成次要墨色，中性的分叉图标，不抢眼）；
/// 失败是胭脂——赭黄只给等你确认。点它就地展开每个子代理，再点收起。会话在等子代理时这一行就是对话末尾的进展，不再另写一行状态。
/// 展开的每个子代理：状态点、名字、角色与模型、运行了多久（或用时）；下面是状态词加在做什么的一句话——在跑的一行（当前工具），
/// 落定的整句写全（FireCode 名册里的结果首句或失败原因；交回的全文在对话里那张 FireCode 卡片）。没有子代理时不画。
struct PiSubagentList: View {
    let agents: [PiSubagentState]
    @Environment(\.palette) private var palette
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = false

    var body: some View {
        if let summary = PiSubagentSummary(agents) {
            VStack(alignment: .leading, spacing: 8) {
                header(summary)
                if expanded {
                    ForEach(agents, id: \.name) { row($0) }
                }
            }
            .animation(Motion.spatial(Motion.snappy, reduceMotion: reduceMotion), value: expanded)
        }
    }

    private func header(_ summary: PiSubagentSummary) -> some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: 6) {
                if summary.running > 0 {
                    PiStateDot(shown: PiShown(status: .working(.delegating)), size: 7)
                } else {
                    Image(systemName: "arrow.triangle.branch").foregroundStyle(palette.ink3).accessibilityHidden(true)
                }
                Text(summary.lead).fontWeight(summary.running > 0 ? .medium : .regular)
                    .foregroundStyle(summary.running > 0 ? palette.ink : palette.ink3).monospacedDigit()
                if let tail = summary.tail {
                    Dot()
                    Text(tail).foregroundStyle(palette.ink3).monospacedDigit()
                }
                if let failure = summary.failure {
                    Dot().foregroundStyle(palette.failure)
                    Text(failure).foregroundStyle(palette.failure).monospacedDigit()
                }
                DisclosureChevron(open: expanded)
            }
            .font(Typography.secondary)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Dotted(summary.lead, summary.tail, summary.failure).spoken)
        .accessibilityValue(expanded ? "已展开" : "已收起")
    }

    private func row(_ agent: PiSubagentState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                PiStateDot(shown: agent.shown, size: 7)
                Text(agent.name).foregroundStyle(palette.ink2).lineLimit(1)
                Text("\(agent.role)\(agent.model.map { model in Text("\(Dotted.separator)\(BrandMark.label(.model(reference: model), PiModelName.short(model)))") } ?? Text(verbatim: ""))")
                    .foregroundStyle(palette.ink3).lineLimit(1)
                Spacer(minLength: 8)
                if let clock = PiSubagentClock(agent) { Elapsed(clock: clock) }
            }
            .font(Typography.secondary)
            Text("\(Text(agent.label).foregroundStyle(agent.shown.labelTint(palette)))\(Text(agent.action.isEmpty ? "" : "\(Dotted.separator)\(agent.action)").foregroundStyle(palette.ink3))")
                .font(Typography.meta)
                .lineLimit(agent.isRunning ? 1 : nil).truncationMode(.tail)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, 13)
                .accessibilityLabel(Dotted(agent.label, agent.action).spoken)
        }
        .accessibilityElement(children: .combine)
        .transition(.opacity)
    }

    /// 在跑的是系统计时文本；落定的是定值。
    private struct Elapsed: View {
        let clock: PiSubagentClock
        @Environment(\.palette) private var palette

        var body: some View {
            Group {
                switch clock {
                case .running(let running): PiClockText(clock: running)
                case .took: Text(clock.text(now: .now))
                }
            }
            .font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3)
        }
    }
}
