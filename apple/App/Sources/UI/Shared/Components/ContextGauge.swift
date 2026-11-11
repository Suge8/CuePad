import CueStore
import SwiftUI

/// 不用一条短横（挨着数字读成减号"−86%"），也不用圈里一块扇形（像录制钮或表盘）。
/// 胭脂字压在胭脂铺色上，深色下到不了 4.5:1，颜色只放在铺色上，字留给墨色。
/// 接近上限时点开的气泡里多一个"压缩"，等于发出 /compact（会话能用斜杠命令时，`AgentCapabilities.commands`）。
struct ContextGauge: View {
    let session: SessionState
    let meter: ContextMeter
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @State private var showsDetail = false
    @ScaledMetric(relativeTo: .footnote) private var ringSide: CGFloat = 11
    private static let ringLine: CGFloat = 2

    private var tight: Bool { meter.level == .tight || meter.level == .critical }

    private var used: Color {
        switch meter.level {
        case .critical: palette.failureTrack
        case .tight: palette.track
        case .roomy: palette.hair
        }
    }

    var body: some View {
        Button { showsDetail.toggle() } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: Spacing.tight) { Text("上下文").foregroundStyle(palette.ink3); percent }
                HStack(spacing: Spacing.tight) { ring; percent }
                ring
            }
            .chip(level: ControlSurface.Level(fraction: meter.fraction, color: used))
        }
        .buttonStyle(PressStyle())
        .help(meter.help.visible)
        .bubble(isPresented: $showsDetail) { detail }
        .accessibilityLabel("上下文")
        .accessibilityValue(meter.help.spoken)
        .animation(Motion.fade, value: meter)
    }

    private var percent: some View {
        Text(meter.percent).monospacedDigit().fontWeight(tight ? .bold : .medium)
            .foregroundStyle(tight ? palette.ink : palette.ink2)
            .fixedSize()
    }

    private var ring: some View {
        ZStack {
            Circle().stroke(palette.track, lineWidth: Self.ringLine)
            Circle().trim(from: 0, to: meter.fraction)
                .stroke(tight ? palette.ink : palette.ink3, style: StrokeStyle(lineWidth: Self.ringLine, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: ringSide, height: ringSide)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            Text("上下文").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
            Text(meter.summary).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if meter.suggestsCompact {
                let compacts = session.capabilities.contains(.commands)
                Text(compacts ? "快满了。Agent 会在到顶前自动压缩，也可以现在压缩。" : "快满了。Agent 会在到顶前自动压缩。")
                    .font(Typography.meta).foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if compacts {
                    Button("现在压缩", icon: .compact, action: compact)
                        .buttonStyle(ControlButtonStyle(size: .compact))
                }
            }
        }
        .padding(Spacing.block)
    }

    private func compact() {
        showsDetail = false
        workspace.speak("/compact", to: .session(session, mode: .command))
    }
}
