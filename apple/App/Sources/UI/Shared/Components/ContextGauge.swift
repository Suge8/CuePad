import CueStore
import SwiftUI

/// 一圈表盘：圈本身就是工具排里的一颗圆钮，用了几成沿着它的边描出来，圈里写百分数。不用一条短横（挨着数字读成减号"−86%"），
/// 也不用圈里一块扇形（像录制钮或表盘）。颜色只描在边上，数字留给墨色（胭脂字在深色下到不了 4.5:1）。
/// 接近上限时点开的气泡里多一个"压缩"，等于发出 /compact。
struct ContextGauge: View {
    let session: SessionState
    let meter: ContextMeter
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.chipHeight) private var chipHeight
    @State private var showsDetail = false
    private static let line: CGFloat = 2.5

    private var tight: Bool { meter.level == .tight || meter.level == .critical }
    private var side: CGFloat { chipHeight ?? ControlSize.inline.height }

    private var arc: Color {
        switch meter.level {
        case .critical: palette.failure
        case .tight: palette.ink
        case .roomy: palette.ink3
        }
    }

    var body: some View {
        Button { showsDetail.toggle() } label: { dial }
            .buttonStyle(PressStyle())
            .help(meter.help.visible)
            .bubble(isPresented: $showsDetail) { detail }
            .accessibilityLabel("上下文")
            .accessibilityValue(meter.help.spoken)
            .animation(Motion.fade, value: meter)
    }

    private var dial: some View {
        ZStack {
            Circle().fill(palette.fill)
            Circle().strokeBorder(palette.track, lineWidth: Self.line)
            Circle().inset(by: Self.line / 2).trim(from: 0, to: meter.fraction)
                .stroke(arc, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // 圈里的字随圈定大，不随动态字体：放大了就撑出圈
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: "\(meter.used)").font(.system(size: side * 0.32, weight: tight ? .bold : .semibold, design: .rounded))
                Text(verbatim: "%").font(.system(size: side * 0.22, weight: .semibold, design: .rounded))
            }
            .monospacedDigit()
            .foregroundStyle(tight ? palette.ink : palette.ink2)
            .contentTransition(.numericText(value: meter.fraction))
            .readerHidden(true)
        }
        .frame(width: side, height: side)
        .contentShape(.circle)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: Spacing.item) {
            Text("上下文").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
            Text(meter.summary).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if meter.suggestsCompact {
                Text("快满了。Agent 会在到顶前自动压缩，也可以现在压缩。")
                    .font(Typography.meta).foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("现在压缩", icon: .compacting, action: compact)
                    .buttonStyle(ControlButtonStyle(size: .compact))
            }
        }
        .padding(Spacing.block)
    }

    private func compact() {
        showsDetail = false
        workspace.compact(session)
    }
}
