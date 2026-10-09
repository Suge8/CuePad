import CueStore
import SwiftUI

/// 排队的话（`PiChat.queued`）：Agent 在跑时"等它做完再说"发出、它还没开始处理的，在回复框上方一小叠（回复框那一层玻璃，
/// 同问题卡），按发出先后，同一句话不再同时是对话末尾的气泡。还没被 Mac 领取的每条可"马上说"或撤回；
/// Mac 已交给 Pi 的写"已交给 Agent"——Pi 的扩展接口没有撤回或提升已进它队列的话（只有 Pi 自己的终端能清队列），所以那之后做不了。
/// 数据只在投送请求里：撤回是删掉它，马上说是改它的方式（`AppServices.withdraw` / `promote`），叠里不另存状态。
struct PiQueueStack: View {
    let requests: [DeliveryRequest]
    @Environment(Workspace.self) private var workspace
    @Environment(\.palette) private var palette

    /// 一叠最多露出几句，其余写个数：它只是提醒，不该把对话挤走。
    private static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("等这一轮做完再说")
                .font(Typography.caption).foregroundStyle(palette.ink3)
                .padding(.horizontal, 6).padding(.top, 2)
                .accessibilityAddTraits(.isHeader)
            ForEach(requests.prefix(Self.shown)) { row($0) }
            if requests.count > Self.shown {
                Text("还有 \(requests.count - Self.shown) 句").font(Typography.caption).foregroundStyle(palette.ink3)
                    .padding(.horizontal, 6).padding(.bottom, 4)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(in: .rect(cornerRadius: Self.radius, style: .continuous))
    }

    private static var radius: CGFloat { 20 }

    private func row(_ request: DeliveryRequest) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(Typography.caption).foregroundStyle(palette.ink3).accessibilityHidden(true)
            Text(PiChat.shownText(of: request))
                .font(Typography.secondary).foregroundStyle(palette.ink2)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if request.isWithdrawable {
                Button { promote(request) } label: {
                    Label(DeliveryMode.steer.label, systemImage: "bolt")
                        .font(Typography.caption.weight(.semibold)).foregroundStyle(palette.ink)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(palette.fill, in: .capsule)
                        .frame(minHeight: Self.target).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .help(DeliveryMode.steer.explanation ?? "")
                Button { withdraw(request) } label: {
                    Image(systemName: "xmark").font(Typography.caption.weight(.semibold)).foregroundStyle(palette.ink3)
                        .frame(width: Self.target, height: Self.target).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel("撤回")
                .help("撤回这句")
            } else {
                Text("已交给 Agent").font(Typography.caption).foregroundStyle(palette.ink3)
                    .frame(minHeight: Self.target)
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

    private func withdraw(_ request: DeliveryRequest) {
        workspace.attempt { try await workspace.services.withdraw(request) }
    }
}
