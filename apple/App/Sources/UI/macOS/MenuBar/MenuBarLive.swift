#if os(macOS)
import CueStore
import SwiftUI

/// 菜单栏面板（`MenuBarPad`）里"在做"那一块：区头写"在做"与在跑的计数（`LiveWorkCount`），下面是此刻在做的会话（`Workspace.liveWork`，要你注意的在前，
/// 行同会话列表 `PiSessionRow` 的紧凑样子）。先列 `limit` 个（面板只是一瞥），多出的收成末尾一行"还有 N 个"，点开就地列全、末行换成"收起"——
/// 看全在原地，不用跳去主窗口；点会话在主窗口里打开它的整页（读与回复在主窗口）。放不下时在里面滚（`HugHeight`）。
/// 手机、iPad 上进行中的会话在进展页的会话段。
struct MenuBarLive: View {
    let work: LiveWork
    let open: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showsAll = false

    private static let limit = 4
    private static let spacing: CGFloat = 9
    private static let style = PiSessionRow.Style.compact

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("在做").font(Typography.label).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                LiveWorkCount(work: work)
            }
            .accessibilityElement(children: .combine)
            HugHeight {
                ScrollView { sessions }.scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var sessions: some View {
        let hidden = max(work.rows.count - Self.limit, 0)
        let shown = hidden > 0 && !showsAll ? Array(work.rows.prefix(Self.limit)) : work.rows
        // 在线的按会话 id 区分：状态变化时那一行不被重建
        return VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(shown) { row($0) }
            if hidden > 0 { LiveMoreFold(hidden: hidden, expanded: $showsAll, style: Self.style) }
        }
        .animation(HandOff.quick, value: showsAll)
    }

    private func row(_ session: PiSessionState) -> some View {
        PiSessionRow(
            session: session, project: workspace.catalog?.project(session.projectID),
            delivery: services.liveSessions.deliveries[session.sessionID], rename: services.liveSessions.renames[session.sessionID],
            undelivered: services.liveSessions.undelivered[session.sessionID] ?? 0).equatable()
            .contentShape(.rect)
            .row()
            .onTapGesture { open(.session(session.sessionID)) }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { open(.session(session.sessionID)) }
    }
}

/// "在做"列末的那一行：收着时写"还有 N 个"，展开后写"收起"；箭头随之转向。
private struct LiveMoreFold: View {
    let hidden: Int
    @Binding var expanded: Bool
    let style: PiSessionRow.Style
    @Environment(\.palette) private var palette

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: style.dot + 2) {
                Text(expanded ? "收起" : "还有 \(hidden) 个").monospacedDigit()
                Image(.expand).font(style.line.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(style.line.weight(.medium)).foregroundStyle(palette.ink3)
            .padding(.leading, style.dot * 1.8 + style.dot + 2)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(expanded ? "收起" : "还有 \(hidden) 个会话")
        .accessibilityExpanded(expanded)
    }
}

/// 区头右边的计数，只写在跑的："2 个在跑 · 2 个子代理"；只有子代理在跑时写"2 个子代理在跑"，都停着写"都停着"。
/// 数字本身就是全部：报不出子代理的那几家不在里面，不另作说明；列了几行不在这里重复（多出的那一行写"还有 N 个"）。
private struct LiveWorkCount: View {
    let work: LiveWork
    @Environment(\.palette) private var palette

    var body: some View {
        Text(text)
            .font(Typography.meta.monospacedDigit()).foregroundStyle(palette.ink3).lineLimit(1)
            .contentTransition(.numericText())
            .animation(HandOff.quick, value: work.running)
            .animation(HandOff.quick, value: work.subagents)
    }

    private var text: Dotted {
        switch (work.running, work.subagents) {
        case (0, 0): "都停着"
        case (0, let agents): Dotted("\(agents) 个子代理在跑")
        case (let sessions, 0): Dotted("\(sessions) 个在跑")
        case (let sessions, let agents): Dotted("\(sessions) 个在跑", "\(agents) 个子代理")
        }
    }
}

/// 让滚动区贴着内容的高：放得下就是内容那么高（外面的玻璃不往下多长一截），放不下就是给的那么高、在里面滚。
/// 不用 `ViewThatFits` 排两份：两份内容各有各的状态
/// （"还有 N 个"展开了，量出来放不下，就换成另一份收着的）。
/// 里面不放懒加载栈：它第一次量出的高是估的（实测估 882、实为 641），下一帧才改成真的，外面的面板挨一下不带动画的改高。
private struct HugHeight: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let scroll = subviews.first else { return .zero }
        let ideal = scroll.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width, height: min(ideal.height, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
    }
}
#endif
