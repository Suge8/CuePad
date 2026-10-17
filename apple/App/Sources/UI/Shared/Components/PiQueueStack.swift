import CueStore
import SwiftUI

/// 排队的话（`PiChat.queued`）：Agent 在跑时发出、它还没读到的，排在回复框那块玻璃的上部、一句两行（话，与它此刻到哪了），
/// 下面一道发丝线隔开输入区（`Composer` 的头部），按发出先后。Agent 读到的那一刻它从这里消失、出现在对话里被读到的位置。
/// `folded` 时（手机上回复框聚焦，键盘已占了半屏）收成一行"N 句排队中 ›"，点它展开。
/// 到哪了只说实话（`PiChat.queueNote`）：还没交到 Agent 手上是"发送中"，排进它的队列后写它什么时候读到。
/// 还没被 Mac 领取的每条可"马上说"（会话做得到时，`steers`）或撤回——撤回的话放回输入框，改了再发；交给 Agent 之后做不了：
/// Pi 的扩展接口没有撤回或改写已进它队列的话（只有 Pi 自己的终端能清队列）。
/// 数据只在投送请求与对话里：撤回是删掉它，马上说是改它的方式（`Workspace.takeBack`、`AppServices.promote`），叠里不另存状态。
struct PiQueueStack: View {
    let requests: [DeliveryRequest]
    let folded: Bool
    /// 这个会话能马上说（`AgentCapabilities.steer`）。
    let steers: Bool
    /// 撤回的话放回的输入框。
    let box: Binding<ComposerDraft>
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    /// 收着时点开了。
    @State private var unfolded = false

    /// 最多露出几句，其余写个数：它只是提醒，不该把对话挤走。
    private static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if folded, !unfolded {
                Button { unfolded = true } label: {
                    HStack(spacing: 6) {
                        Image(.queued).accessibilityHidden(true)
                        Text("\(requests.count) 句排队中")
                        Image(.forward).font(Typography.caption2.weight(.semibold)).accessibilityHidden(true)
                    }
                    .font(Typography.caption).foregroundStyle(palette.ink2)
                    .padding(.horizontal, 6)
                    .frame(maxWidth: .infinity, minHeight: Self.target, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(requests.count) 句排队中")
                .accessibilityHint("展开排队的话")
            } else {
                ForEach(requests.prefix(Self.shown)) { row($0) }
                if requests.count > Self.shown {
                    Text("还有 \(requests.count - Self.shown) 句").font(Typography.caption).foregroundStyle(palette.ink3)
                        .padding(.horizontal, 6).padding(.bottom, 4)
                }
            }
        }
        .padding(.horizontal, 12).padding(.top, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(palette.hair).frame(height: 1).padding(.horizontal, 12) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("等这一轮做完再说")
        // 回复框收起键盘后回到逐句列出
        .onChange(of: folded) { if !folded { unfolded = false } }
    }

    private func row(_ request: DeliveryRequest) -> some View {
        let note = PiChat.queueNote(of: request, at: services.speech)
        return HStack(spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(.queued).font(Typography.caption).foregroundStyle(palette.ink3).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(PiChat.shownText(of: request))
                        .font(Typography.secondary).foregroundStyle(palette.ink2)
                        .lineLimit(1).truncationMode(.tail)
                    Text(note).font(Typography.caption).foregroundStyle(palette.ink3).lineLimit(1)
                        .contentTransition(.opacity)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.vertical, 4)
            // 时钟是装饰：读屏读这句话与它到哪了
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(PiChat.shownText(of: request).spoken)，\(note.spoken)")
            if request.isWithdrawable {
                if steers {
                    Button { promote(request) } label: {
                        Label(DeliveryMode.steer.label, icon: .steer)
                            .font(Typography.caption.weight(.semibold)).foregroundStyle(palette.ink)
                            .padding(.horizontal, 10).frame(height: 26)
                            .background(palette.fill, in: .capsule)
                            .frame(minHeight: Self.target).contentShape(.rect)
                    }
                    .buttonStyle(PressStyle())
                    .accessibilityLabel(DeliveryMode.steer.label)
                    .help(DeliveryMode.steer.explanation ?? "")
                }
                Button { workspace.takeBack(request, into: box) } label: {
                    Image(.restore).font(Typography.caption.weight(.semibold)).foregroundStyle(palette.ink3)
                        .frame(width: Self.target, height: Self.target).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("撤回")
                .accessibilityHint("放回输入框，改了再发")
                .help("撤回这句，放回输入框")
            }
        }
        .padding(.leading, 6)
        // 句子与两颗按钮各自是读屏元素：合成一个时按下它会触发第一颗（马上说），不是读屏用户要的
        .accessibilityElement(children: .contain)
        .transition(.opacity)
    }

    #if os(iOS)
    private static let target: CGFloat = 44
    #else
    private static let target: CGFloat = 28
    #endif

    private func promote(_ request: DeliveryRequest) {
        workspace.attempt { try await workspace.services.promote(request) }
    }

}
