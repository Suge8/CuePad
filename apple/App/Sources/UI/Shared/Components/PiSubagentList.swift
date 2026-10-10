import CueStore
import SwiftUI

/// 会话页对话末尾的子代理：一行汇总"3 个子代理 · 1 在跑 · 1 失败"（有在跑的时前面是转着的状态标，都停了是中性的分叉图标；
/// 失败是胭脂——赭黄只给等你确认），点它就地展开每个子代理，再点收起。会话在等子代理时这一行就是对话末尾的进展，不再另写一行状态。
/// 展开的每个子代理两行：状态点、名字、角色、已运行（或用时）；状态词加在做什么的一句话。没有子代理时不画。
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
                Text(Dotted("\(summary.total) 个子代理", "\(summary.running) 在跑")).foregroundStyle(palette.ink2).monospacedDigit()
                if summary.failed > 0 {
                    Dot().foregroundStyle(palette.failure)
                    Text("\(summary.failed) 失败").foregroundStyle(palette.failure).monospacedDigit()
                }
                Image(systemName: "chevron.down").font(Typography.caption2.weight(.semibold)).foregroundStyle(palette.ink3)
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
            }
            .font(Typography.secondary)
            .frame(minHeight: 32)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityValue(expanded ? "已展开" : "已收起")
    }

    private func row(_ agent: PiSubagentState) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                PiStateDot(shown: agent.shown, size: 7)
                Text(agent.name).foregroundStyle(palette.ink2).lineLimit(1)
                Text(agent.role).foregroundStyle(palette.ink3).lineLimit(1)
                Spacer(minLength: 8)
                if let clock = PiSubagentClock(agent) { Elapsed(clock: clock) }
            }
            .font(Typography.secondary)
            (Text(agent.label).foregroundStyle(agent.shown.labelTint(palette))
                + Text(agent.action.isEmpty ? "" : "\(Dotted.separator)\(agent.action)").foregroundStyle(palette.ink3))
                .font(Typography.meta)
                .lineLimit(1).truncationMode(.tail)
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
