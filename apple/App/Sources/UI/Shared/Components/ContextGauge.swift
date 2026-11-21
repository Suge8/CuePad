import CueStore
import SwiftUI

/// 一圈表盘：圈本身就是工具排里的一颗圆钮，用了几成沿着它的边描出来，圈里写百分数。不用一条短横（挨着数字读成减号"−86%"），
/// 也不用圈里一块扇形（像录制钮或表盘）。描的那一段像一道彗星：起点淡、头上实，一眼看出往哪走、走到了哪；轨道上 80% 处一个小点，
/// 是开始建议压缩的地方（`ContextMeter.compactFraction`），走过去就被盖住。颜色只描在边上，数字留给墨色（胭脂字在深色下到不了 4.5:1）。
/// 都是静止的图形，只在用量变了时补一段过渡。接近上限时点开的气泡里多一个"压缩"，等于发出 /compact。
struct ContextGauge: View {
    let session: SessionState
    let meter: ContextMeter
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette
    @Environment(\.chipHeight) private var chipHeight
    @State private var showsDetail = false
    private static let line: CGFloat = 2.5
    /// 用得再少也露出一小截弧：只剩圆头的一个点读不出是"用了一点"
    private static let least = 0.03

    private var tight: Bool { meter.level == .tight || meter.level == .critical }
    private var side: CGFloat { chipHeight ?? ControlSize.inline.height }
    private var shown: Double { max(meter.fraction, Self.least) }

    private var arc: Color {
        switch meter.level {
        case .critical: palette.failure
        case .tight: palette.ink
        case .roomy: palette.ink2
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
            if !meter.suggestsCompact {
                Circle().fill(palette.ink3).frame(width: Self.line, height: Self.line)
                    .offset(y: -(side - Self.line) / 2)
                    .rotationEffect(.degrees(360 * ContextMeter.compactFraction))
                    .transition(.opacity)
            }
            Circle().inset(by: Self.line / 2).trim(from: 0, to: shown)
                .stroke(
                    AngularGradient(colors: [arc.opacity(0.2), arc], center: .center, startAngle: .zero, endAngle: .degrees(360 * shown)),
                    style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                .rotationEffect(.degrees(-90))
            // 圈里的字随圈定大，不随动态字体：放大了就撑出圈
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(verbatim: "\(meter.used)").font(.system(size: side * 0.32, weight: tight ? .bold : .semibold, design: .rounded))
                Text(verbatim: "%").font(.system(size: side * 0.2, weight: .semibold, design: .rounded)).foregroundStyle(palette.ink3)
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
