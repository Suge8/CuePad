import CueStore
import SwiftUI

/// 回复框工具排里思考强度条旁的上下文用量（iOS 与 Mac 共用，读数规则见 `PiContextMeter`）：胶囊里写"上下文 86%"，
/// 胶囊自己就是用量计——底下从左铺一层淡色，铺到已用的比例。写出"上下文"三个字，数字不会被读成别的；工具排放不下时（`ConfigRow`）
/// 三个字收成一个小圆环：淡圈上一道弧描到已用的比例，静止、紧挨着百分比，读得出是用量。不用一条短横（挨着数字读成减号"−86%"），
/// 也不用圈里一块扇形（像录制钮或表盘）。
/// 与模型、思考强度同样高；用到七成百分比加粗转墨色、铺色加深；九成时铺色换成胭脂（赭黄只给等你确认），百分比仍是墨色加粗——
/// 胭脂字压在胭脂铺色上，深色下到不了 4.5:1，颜色只放在铺色上，字留给墨色。刚压缩过、Agent 还不知道
/// 已用多少时没有这颗胶囊。悬停与读屏说"上下文 · 已用 x% · 剩 y%"（快满了加一句可以压缩）；点一下是同样的说明，
/// 接近上限时多一个"压缩"，等于发出 /compact（会话能用斜杠命令时，`AgentCapabilities.commands`）。
struct PiContextGauge: View {
    let session: PiSessionState
    let meter: PiContextMeter
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showsDetail = false
    @ScaledMetric(relativeTo: .footnote) private var ringSide: CGFloat = 11
    private static let ringLine: CGFloat = 2

    /// 百分比：余量足次要墨色，七成起墨色加粗（快满了也是墨色，胭脂只在铺色上）。
    private var tight: Bool { meter.level == .tight || meter.level == .critical }

    /// 胶囊里铺到已用比例的那层淡色：比胶囊底深一档，紧了再深一点，快满了换成胭脂。
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
                HStack(spacing: 4) { Text("上下文").foregroundStyle(palette.ink3); percent }
                HStack(spacing: 4) { ring; percent }
            }
            .font(Typography.meta)
            .padding(.horizontal, 10)
            .frame(height: ConfigCapsule.height)
            .background(palette.fill, in: .capsule)
            .background(alignment: .leading) {
                GeometryReader { proxy in
                    used.frame(width: proxy.size.width * meter.fraction)
                }
                .clipShape(.capsule)
            }
            .frame(minHeight: 44)
            .contentShape(.capsule)
        }
        .buttonStyle(PressStyle())
        .help(meter.help.visible)
        .popover(isPresented: $showsDetail) { detail.presentationCompactAdaptation(.popover) }
        .accessibilityLabel("上下文")
        .accessibilityValue(meter.help.spoken)
        .animation(Motion.quick, value: meter)
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
        VStack(alignment: .leading, spacing: 10) {
            Text("上下文").font(Typography.secondary.weight(.semibold)).foregroundStyle(palette.ink)
            Text(meter.summary).font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if meter.suggestsCompact {
                let compacts = session.capabilities.contains(.commands)
                Text(compacts ? "快满了。Agent 会在到顶前自动压缩，也可以现在压缩。" : "快满了。Agent 会在到顶前自动压缩。")
                    .font(Typography.meta).foregroundStyle(palette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                if compacts {
                    Button("压缩上下文", icon: .compact, action: compact)
                        .buttonStyle(.glass).controlSize(.small)
                }
            }
        }
        .padding(16)
        .frame(minWidth: 220, maxWidth: 300, alignment: .leading)
    }

    private func compact() {
        showsDetail = false
        workspace.speak("/compact", to: .session(session, mode: .command))
    }
}
