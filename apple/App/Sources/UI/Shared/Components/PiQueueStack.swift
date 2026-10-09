import CueStore
import SwiftUI

/// 排队的话（`PiChat.queued`）：Agent 在跑时"等它做完再说"发出、它还没开始处理的，排在回复框那块玻璃的上部、一句一行，
/// 下面一道发丝线隔开输入区（`Composer` 的头部），按发出先后，同一句话不再同时是对话末尾的气泡。`folded` 时（手机上回复框聚焦，
/// 键盘已占了半屏）收成一行"N 句排队中 ›"，点它展开。还没被 Mac 领取的每条可"马上说"或撤回；
/// Mac 已交给 Pi 的写"已交给 Agent"——Pi 的扩展接口没有撤回或提升已进它队列的话（只有 Pi 自己的终端能清队列），所以那之后做不了。
/// 数据只在投送请求里：撤回是删掉它，马上说是改它的方式（`AppServices.withdraw` / `promote`），叠里不另存状态。
struct PiQueueStack: View {
    let requests: [DeliveryRequest]
    let folded: Bool
    @Environment(Workspace.self) private var workspace
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
                        Image(systemName: "clock").accessibilityHidden(true)
                        Text("\(requests.count) 句排队中")
                        Image(systemName: "chevron.right").font(Typography.caption2.weight(.semibold)).accessibilityHidden(true)
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
        HStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "clock").font(Typography.caption).foregroundStyle(palette.ink3).accessibilityHidden(true)
                Text(PiChat.shownText(of: request))
                    .font(Typography.secondary).foregroundStyle(palette.ink2)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            // 时钟是装饰：读屏只读这句话
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(PiChat.shownText(of: request))
            if request.isWithdrawable {
                Button { promote(request) } label: {
                    Label(DeliveryMode.steer.label, systemImage: "bolt")
                        .font(Typography.caption.weight(.semibold)).foregroundStyle(palette.ink)
                        .padding(.horizontal, 10).frame(height: 26)
                        .background(palette.fill, in: .capsule)
                        .frame(minHeight: Self.target).contentShape(.rect)
                }
                .buttonStyle(PressStyle())
                .accessibilityLabel(DeliveryMode.steer.label)
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
