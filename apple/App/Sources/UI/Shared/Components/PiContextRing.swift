import CueStore
import SwiftUI

/// 回复框工具排里思考强度条旁的上下文圆环（iOS 与 Mac 共用，读数规则见 `PiContextMeter`）：画法与任务完成圈一样——实线圈里一块从 12 点
/// 顺时针的扇形，扇形是已用的比例；圈旁一个百分比小字（`percent`），一眼看得出是用量。不画"淡圈上描一道弧"：小尺寸下那就是系统的加载转圈。
/// 与旁边的模型、思考强度同样垫一块同高的淡胶囊；圈线细（1.5），扇形是次要墨色，读作用量而不是录制钮或时钟。
/// 用到七成只把百分比加粗、转墨色，九成胭脂（赭黄只给等你确认）；刚压缩过、Agent 还不知道已用多少时是一个空圈、旁边一道横线。
/// 悬停与读屏说"上下文 · 已用 x% · 剩 y tokens"（快满了加一句可以压缩）；点一下是同样的说明，接近上限时多一个"压缩"，等于发出 /compact。
struct PiContextRing: View {
    let session: PiSessionState
    let usage: PiContextUsage
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showsDetail = false

    private static let diameter: CGFloat = 16
    private static let lineWidth: CGFloat = 1.5

    private var meter: PiContextMeter { PiContextMeter(usage) }

    /// 圈与扇形：快满（九成）胭脂，其余次要墨色——用量紧不紧由百分比的字重说。
    private var tint: Color { meter.level == .critical ? palette.failure : palette.ink2 }

    private var percentTint: Color {
        switch meter.level {
        case .critical: palette.failure
        case .tight: palette.ink
        case .roomy, .unknown: palette.ink2
        }
    }

    var body: some View {
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 5) {
                ring.frame(width: Self.diameter, height: Self.diameter)
                Text(meter.percent).font(Typography.meta.monospacedDigit().weight(meter.level == .roomy || meter.level == .unknown ? .medium : .bold))
                    .foregroundStyle(percentTint)
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

    @ViewBuilder private var ring: some View {
        if let fraction = meter.fraction {
            ZStack {
                Circle().stroke(tint, lineWidth: Self.lineWidth)
                // 与圈线之间留一线缝，扇形的边才读得出来；几乎没用时也留一道细边，看得出这是一个有读数的圈
                Sector(fraction: max(fraction, 0.03)).fill(tint).padding(Self.lineWidth * 1.6)
            }
        } else {
            // 不画虚线圈：小尺寸下虚线圈像加载中
            Circle().stroke(tint, lineWidth: Self.lineWidth)
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("上下文", systemImage: "circle.dashed").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
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
