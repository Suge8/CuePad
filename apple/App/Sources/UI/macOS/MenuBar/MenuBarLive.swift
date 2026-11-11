#if os(macOS)
import CueStore
import SwiftUI

/// 区头只写"在做"：几件推进中已写在面板顶上的数字账（`CueLedger`），不另按会话数一遍。
struct MenuBarLive: View {
    let rows: [SessionState]
    let open: (Route) -> Void
    @Environment(Workspace.self) private var workspace
    @Environment(AppServices.self) private var services
    @Environment(\.palette) private var palette
    @State private var showsAll = false

    private static let limit = 4
    private static let spacing: CGFloat = 9
    private static let style = SessionRow.Style.compact

    var body: some View {
        VStack(alignment: .leading, spacing: Self.spacing) {
            Text("在做").font(Typography.label).foregroundStyle(palette.ink3).accessibilityAddTraits(.isHeader)
            HugHeight {
                ScrollView { sessions }.scrollBounceBehavior(.basedOnSize)
            }
        }
    }

    private var sessions: some View {
        let hidden = max(rows.count - Self.limit, 0)
        let shown = hidden > 0 && !showsAll ? Array(rows.prefix(Self.limit)) : rows
        // 在线的按会话 id 区分：状态变化时那一行不被重建
        return VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(shown) { row($0) }
            if hidden > 0 { LiveMoreFold(hidden: hidden, expanded: $showsAll, style: Self.style) }
        }
        .animation(Motion.fade, value: showsAll)
    }

    private func row(_ session: SessionState) -> some View {
        SessionRow(
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

private struct LiveMoreFold: View {
    let hidden: Int
    @Binding var expanded: Bool
    let style: SessionRow.Style
    @Environment(\.palette) private var palette

    var body: some View {
        Button { expanded.toggle() } label: {
            HStack(spacing: style.dot + Spacing.hair) {
                Text(expanded ? "收起" : "还有 \(hidden) 个").monospacedDigit()
                Image(.expand).font(style.line.weight(.semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
            }
            .font(style.line.weight(.medium)).foregroundStyle(palette.ink3)
            .padding(.leading, style.dot * 1.8 + style.dot + Spacing.hair)
            .frame(minHeight: 28)
            .contentShape(.rect)
        }
        .buttonStyle(PressStyle())
        .accessibilityLabel(expanded ? "收起" : "还有 \(hidden) 个会话")
        .accessibilityExpanded(expanded)
    }
}

/// 不用 `ViewThatFits` 排两份：两份内容各有各的状态（"还有 N 个"展开了，量出来放不下，就换成另一份收着的）。
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
