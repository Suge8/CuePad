import CueStore
import SwiftUI

/// 回复框工具排里思考强度条旁的上下文用量（iOS 与 Mac 共用，读数规则见 `PiContextMeter`）：一条横着的细用量条，填满的部分是已用的比例，
/// 旁边一个百分比小字（`percent`）。不画圆：圈里一块扇形像录制钮或表盘，淡圈上描一道弧在小尺寸下就是系统的加载转圈；
/// 横条与旁边竖着长高的思考强度格也分得开。与模型、思考强度同样垫一块同高的淡胶囊，条是次要墨色。
/// 用到七成百分比加粗、条与字转墨色，九成胭脂（赭黄只给等你确认）；刚压缩过、Agent 还不知道已用多少时是一条空槽、旁边一道横线。
/// 悬停与读屏说"上下文 · 已用 x% · 剩 y tokens"（快满了加一句可以压缩）；点一下是同样的说明，接近上限时多一个"压缩"，等于发出 /compact。
struct PiContextGauge: View {
    let session: PiSessionState
    let usage: PiContextUsage
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showsDetail = false

    private static let barSize = CGSize(width: 22, height: 5)

    private var meter: PiContextMeter { PiContextMeter(usage) }

    /// 条与百分比同色：余量足次要墨色，七成墨色，九成胭脂。
    private var tint: Color {
        switch meter.level {
        case .critical: palette.failure
        case .tight: palette.ink
        case .roomy, .unknown: palette.ink2
        }
    }

    var body: some View {
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 5) {
                bar
                Text(meter.percent).font(Typography.meta.monospacedDigit().weight(meter.level == .roomy || meter.level == .unknown ? .medium : .bold))
                    .foregroundStyle(tint)
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(palette.fill, in: .capsule)
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(meter.help)
        .popover(isPresented: $showsDetail) { detail.presentationCompactAdaptation(.popover) }
        .accessibilityLabel("上下文")
        .accessibilityValue(meter.help)
        .animation(Motion.quick, value: meter)
    }

    /// 空槽是淡色，已用的部分从左填起；几乎没用时也露一小截，看得出这是一条有读数的条。
    private var bar: some View {
        Capsule().fill(tint.opacity(0.22))
            .overlay(alignment: .leading) {
                if let fraction = meter.fraction {
                    Capsule().fill(tint).frame(width: Self.barSize.width * max(fraction, 0.08))
                }
            }
            .frame(width: Self.barSize.width, height: Self.barSize.height)
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("上下文").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
            Text(meter.summary).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if meter.suggestsCompact {
                Text("快满了。Agent 会在到顶前自动压缩，也可以现在压缩。").font(Typography.meta).foregroundStyle(palette.ink2)
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
