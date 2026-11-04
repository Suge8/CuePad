#if os(iOS)
import CueStore
import SwiftUI

/// 窄屏的"更早"（WORDS.md）：已结束的会话。Cue 页会话条最底下一格写"更早"与个数，点它推入"更早"那一页（`Route.earlier`）；
/// 宽屏同一件事在会话条里原地展开（`RailEarlier`）。个数与那一页读同一个查询（`PiSessionList.earlier`：置顶任务上的也在里面，正在唤醒的不在），两边对得上。
/// 没有已结束的会话时这一格不画：没有可去的地方。
struct EarlierTile: View {
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var total: Int?

    var body: some View {
        Group {
            if let total, total > 0 {
                Button { workspace.push(.earlier) } label: {
                    VStack(spacing: 1) {
                        Text("更早").foregroundStyle(palette.ink2)
                        Text(total, format: .number).foregroundStyle(palette.ink3).monospacedDigit()
                    }
                    .font(Typography.caption2.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: Self.height)
                    .contentShape(.rect)
                }
                .buttonStyle(PressStyle(.card))
                .paper(cornerRadius: Radius.block)
                .accessibilityLabel(Text("更早"))
                .accessibilityValue(Text(total, format: .number))
            } else {
                // 读库的订阅要挂在一个真的视图上（docs/layout.md）
                Color.clear.frame(height: 0)
            }
        }
        .padding(.horizontal, SessionRail.phoneInset)
        .frame(width: SessionRail.Form.phone.width)
        .dynamicTypeSize(...DynamicTypeSize.xxLarge)
        .observing(services.store, id: services.speech, into: $total, onError: workspace.fail) { [moment = services.speech] store in
            try PiSessionList.earlier(PiSessionQuery(limit: 1), at: moment, from: store).total
        }
    }

    /// 同会话条一格那么高：两行小字，手指点得到。
    private static let height: CGFloat = 44
}

/// "更早"那一页：已结束的会话按结束时间分段（`SessionList` 的历史，`AgentListModel.endedOnly`），滑到底再读一页。推入的页，左边是系统返回。
/// 在跑、等你的会话不在这里，它们在会话条上。
struct EarlierScreen: View {
    @State private var model = AgentListModel(endedOnly: true)

    var body: some View {
        SessionList(model: model).floatingHeader("更早")
    }
}
#endif
