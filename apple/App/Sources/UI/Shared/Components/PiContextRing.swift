import CueStore
import SwiftUI

/// 回复框工具排里思考强度条旁的上下文圆环（iOS 与 Mac 共用，读数规则见 `PiContextMeter`）：圆弧是已用的比例，
/// 余量充足时中性，用到七成赭黄、九成胭脂；刚压缩过、Agent 还不知道已用多少时画成虚线圈。
/// 点一下（Mac 悬停也有提示）说"已用 x% · 剩 y tokens"；接近上限时多一个"压缩"，等于发出 /compact。
struct PiContextRing: View {
    let session: PiSessionState
    let usage: PiContextUsage
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showsDetail = false

    private static let diameter: CGFloat = 18
    private static let lineWidth: CGFloat = 2.5

    private var meter: PiContextMeter { PiContextMeter(usage) }

    private var tint: Color {
        switch meter.level {
        case .roomy: palette.ink2
        case .tight: palette.attention
        case .critical: palette.failure
        case .unknown: palette.ink3
        }
    }

    var body: some View {
        Button { showsDetail.toggle() } label: {
            ring
                .frame(width: Self.diameter, height: Self.diameter)
                .padding(13)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .help(meter.summary)
        .popover(isPresented: $showsDetail) { detail.presentationCompactAdaptation(.popover) }
        .accessibilityLabel("上下文")
        .accessibilityValue(meter.summary)
        .animation(Motion.quick, value: meter)
    }

    @ViewBuilder private var ring: some View {
        if let fraction = meter.fraction {
            ZStack {
                Circle().stroke(palette.ink.opacity(0.14), lineWidth: Self.lineWidth)
                Circle().trim(from: 0, to: max(fraction, 0.02))
                    .stroke(tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
        } else {
            Circle().stroke(tint, style: StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [2, 3.2]))
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("上下文", systemImage: "circle.dashed").font(.subheadline.weight(.semibold)).foregroundStyle(palette.ink)
            Text(meter.summary).font(.footnote.monospacedDigit()).foregroundStyle(palette.ink2)
            if meter.suggestsCompact {
                Text("快满了。Agent 会在到顶前自动压缩，也可以现在压缩。").font(.footnote).foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                Button("压缩上下文", systemImage: "arrow.down.right.and.arrow.up.left", action: compact)
                    .buttonStyle(.glass).controlSize(.small)
            }
        }
        .padding(16)
        .frame(minWidth: 220, maxWidth: 300, alignment: .leading)
    }

    private func compact() {
        showsDetail = false
        workspace.attempt { _ = try await services.requestMacDelivery("/compact", to: session, mode: .command) }
    }
}
