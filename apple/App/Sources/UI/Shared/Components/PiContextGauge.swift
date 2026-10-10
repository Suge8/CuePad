import CueStore
import SwiftUI

/// 回复框工具排里思考强度条旁的上下文用量（iOS 与 Mac 共用，读数规则见 `PiContextMeter`）：胶囊里写"上下文 86%"，
/// 胶囊自己就是用量计——底下从左铺一层淡色，铺到已用的比例。不另画小图形：圈里一块扇形像录制钮或表盘，淡圈上描一道弧
/// 在小尺寸下就是加载转圈，挨着数字的一条短横会读成减号（"−86%"）；写出"上下文"三个字，数字也不会被读成别的。
/// 与模型、思考强度同样高；用到七成百分比加粗转墨色、铺色加深；九成时铺色换成胭脂（赭黄只给等你确认），百分比仍是墨色加粗——
/// 胭脂字压在胭脂铺色上，深色下到不了 4.5:1，颜色只放在铺色上，字留给墨色。刚压缩过、Agent 还不知道
/// 已用多少时不铺色、数字是一道横线。悬停与读屏说"上下文 · 已用 x% · 剩 y%"（快满了加一句可以压缩）；点一下是同样的说明，
/// 接近上限时多一个"压缩"，等于发出 /compact。
struct PiContextGauge: View {
    let session: PiSessionState
    let usage: PiContextUsage
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showsDetail = false

    private var meter: PiContextMeter { PiContextMeter(usage) }

    /// 百分比：余量足次要墨色，七成起墨色加粗（快满了也是墨色，胭脂只在铺色上）。
    private var tight: Bool { meter.level == .tight || meter.level == .critical }

    /// 胶囊里铺到已用比例的那层淡色：比胶囊底深一档，紧了再深一点，快满了换成胭脂。
    private var used: Color {
        switch meter.level {
        case .critical: palette.failure.opacity(0.2)
        case .tight: palette.ink.opacity(0.13)
        case .roomy, .unknown: palette.ink.opacity(0.08)
        }
    }

    var body: some View {
        Button { showsDetail.toggle() } label: {
            HStack(spacing: 4) {
                Text("上下文").foregroundStyle(palette.ink3)
                Text(meter.percent).monospacedDigit().fontWeight(tight ? .bold : .medium)
                    .foregroundStyle(tight ? palette.ink : palette.ink2)
            }
            .font(Typography.meta)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(palette.fill, in: .capsule)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    if let fraction = meter.fraction { used.frame(width: proxy.size.width * fraction) }
                }
                .clipShape(.capsule)
            }
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .help(meter.help.visible)
        .popover(isPresented: $showsDetail) { detail.presentationCompactAdaptation(.popover) }
        .accessibilityLabel("上下文")
        .accessibilityValue(meter.help.spoken)
        .animation(Motion.quick, value: meter)
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
